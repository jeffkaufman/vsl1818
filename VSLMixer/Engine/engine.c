#include "engine.h"
#include "jammer_link.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_FRAMES 4096            // largest IO buffer we accept
#define MAX_DEVICE_CHANNELS 64
#define RING_FRAMES (1 << 18)      // ~5 s at 48 kHz of recording slack
#define REC_TRACKS (MX_CHANNELS + 2)   // the inputs, then jacks 1 and 2 under Jammer
// Inputs and mixes share the processing code: strip c < MX_CHANNELS is an
// input, strip MX_CHANNELS + m is mix m.
#define STRIPS (MX_CHANNELS + MX_MIXES)
#define DELAY_FRAMES (1 << 15)     // MX_MAX_DELAY_MS at up to 96 kHz
#define DELAY_XFADE 256            // samples to crossfade when a delay changes
#define LIMIT_RELEASE_MS 100

// ---------------------------------------------------------------- filters

typedef struct {
    double b0, b1, b2, a1, a2;
    double z1, z2;
} biquad;

static void bq_set(biquad *q, double b0, double b1, double b2, double a0,
                   double a1, double a2) {
    q->b0 = b0 / a0; q->b1 = b1 / a0; q->b2 = b2 / a0;
    q->a1 = a1 / a0; q->a2 = a2 / a0;
}

static double clamp_hz(double f, double fs) {
    if (f < 10) return 10;
    if (f > 0.45 * fs) return 0.45 * fs;
    return f;
}

static void bq_highpass(biquad *q, double fs, double f) {
    double w = 2 * M_PI * clamp_hz(f, fs) / fs, c = cos(w);
    double alpha = sin(w) / (2 * M_SQRT1_2);  // Butterworth, Q = 1/sqrt(2)
    bq_set(q, (1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

static void bq_peak(biquad *q, double fs, double f, double db, double Q) {
    double A = pow(10, db / 40), w = 2 * M_PI * clamp_hz(f, fs) / fs;
    double c = cos(w), alpha = sin(w) / (2 * (Q < 0.1 ? 0.1 : Q));
    bq_set(q, 1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c,
           1 - alpha / A);
}

static void bq_shelf(biquad *q, double fs, double f, double db, bool high) {
    double A = pow(10, db / 40), w = 2 * M_PI * clamp_hz(f, fs) / fs;
    double c = cos(w), s = sin(w);
    double ta = 2 * sqrt(A) * (s / 2 * M_SQRT2);  // shelf slope S = 1
    if (high)
        bq_set(q, A * ((A + 1) + (A - 1) * c + ta), -2 * A * ((A - 1) + (A + 1) * c),
               A * ((A + 1) + (A - 1) * c - ta), (A + 1) - (A - 1) * c + ta,
               2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - ta);
    else
        bq_set(q, A * ((A + 1) - (A - 1) * c + ta), 2 * A * ((A - 1) - (A + 1) * c),
               A * ((A + 1) - (A - 1) * c - ta), (A + 1) + (A - 1) * c + ta,
               -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - ta);
}

static inline float bq_run(biquad *q, float x) {
    double y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return (float)y;
}

static double bq_response_db(const biquad *q, double fs, double f) {
    double w = 2 * M_PI * f / fs;
    double c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    double nr = q->b0 + q->b1 * c1 + q->b2 * c2, ni = -(q->b1 * s1 + q->b2 * s2);
    double dr = 1 + q->a1 * c1 + q->a2 * c2, di = -(q->a1 * s1 + q->a2 * s2);
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

enum { BQ_HPF, BQ_LOW, BQ_MID, BQ_HIGH, BQ_COUNT };

static void design_filters(biquad bq[BQ_COUNT], const mx_channel_settings *s,
                           double fs) {
    bq_highpass(&bq[BQ_HPF], fs, s->hpf_hz);
    bq_shelf(&bq[BQ_LOW], fs, s->low_hz, s->low_db, false);
    bq_peak(&bq[BQ_MID], fs, s->mid_hz, s->mid_db, s->mid_q);
    bq_shelf(&bq[BQ_HIGH], fs, s->high_hz, s->high_db, true);
}

double mx_eq_response_db(const mx_channel_settings *s, double fs, double f) {
    biquad bq[BQ_COUNT];
    design_filters(bq, s, fs);
    double db = 0;
    if (s->hpf_on) db += bq_response_db(&bq[BQ_HPF], fs, f);
    if (s->eq_on)
        for (int i = BQ_LOW; i <= BQ_HIGH; i++) db += bq_response_db(&bq[i], fs, f);
    return db;
}

// ---------------------------------------------------------------- engine

typedef struct {
    // what the IO thread is currently using
    mx_channel_settings s;
    biquad bq[BQ_COUNT];
    biquad bq_r[BQ_COUNT];   // the right side, for a stereo mix
    float att_coef, rel_coef, inv_ratio;
    float env;          // compressor peak envelope, linear
    float mute_gain;    // smoothed
} channel_rt;

typedef struct {
    float buf[DELAY_FRAMES];
    uint32_t w;
    int cur, next;  // delay in samples, and where a crossfade is heading
    int xf;         // crossfade samples remaining
} delay_line;

// Writes x and returns the sample `target` frames ago.  A change of target
// crossfades between the old and new taps so it doesn't click; one that
// arrives mid-crossfade waits for it to finish.  At 0 it's passthrough.
static inline float delay_run(delay_line *d, float x, int target) {
    d->buf[d->w & (DELAY_FRAMES - 1)] = x;
    if (d->xf == 0 && target != d->cur) {
        d->next = target;
        d->xf = DELAY_XFADE;
    }
    float y = d->buf[(d->w - d->cur) & (DELAY_FRAMES - 1)];
    if (d->xf > 0) {
        float t = 1.f - (float)d->xf / DELAY_XFADE;
        float b = d->buf[(d->w - d->next) & (DELAY_FRAMES - 1)];
        y += t * (b - y);
        if (--d->xf == 0) d->cur = d->next;
    }
    d->w++;
    return y;
}

struct mx_engine {
    // ---- written by the UI thread, read by the IO thread
    mx_channel_settings pending[STRIPS];
    _Atomic uint32_t seq[STRIPS];  // seqlock around pending[]
    _Atomic float send[MX_MIXES][MX_CHANNELS];
    _Atomic float master[MX_MIXES];
    _Atomic bool muted[STRIPS];
    _Atomic float delay_ms[MX_MIXES];
    _Atomic float pan[MX_MIXES][MX_CHANNELS];
    _Atomic float limit_db[MX_MIXES];
    _Atomic bool linked[MX_PAIRS];

    // ---- IO thread only
    double fs;
    float smooth;   // one-pole coefficient for gain changes
    uint32_t applied_seq[STRIPS];
    channel_rt ch[STRIPS];
    float send_l[MX_MIXES][MX_CHANNELS];   // send x pan, smoothed; a mono
    float send_r[MX_MIXES][MX_CHANNELS];   // mix uses only send_l
    float master_g[MX_MIXES];
    delay_line delay[MX_MIXES];
    delay_line delay_r[MX_PAIRS];   // the right side of a linked pair's mix
    bool link_cur[MX_PAIRS];        // the routing in use; follows linked[] once
    float pair_gain[MX_PAIRS];      // the pair has faded out
    float lim_g[MX_MIXES];          // limiter gain
    float lim_rel;                  // limiter release, per sample
    double last_in_time;
    float in_scratch[MAX_FRAMES * MX_CHANNELS];
    float jack_scratch[MAX_FRAMES * 2];   // jacks 1 and 2 while Jammer replaces them
    const float *jacks;                   // into it, or NULL when they aren't replaced
    double in_host;                       // host time of this cycle's first input frame
    double ticks_per_frame;               // host clock ticks per sample
    float out_scratch[MAX_FRAMES * MX_OUTPUTS];

    // ---- written by the IO thread, read by the UI thread
    _Atomic float in_peak[MX_CHANNELS];
    _Atomic float mix_in_peak[MX_MIXES];
    _Atomic float gr_db[STRIPS];
    _Atomic float mix_peak[MX_MIXES];
    _Atomic float limit_gr[MX_MIXES];
    _Atomic float out_peak[MX_OUTPUTS];
    float scope[MX_SCOPE_FRAMES][STRIPS];
    _Atomic uint32_t scope_w;
    _Atomic uint64_t callbacks;
    _Atomic uint32_t dropouts;

    // ---- device
    AudioObjectID device;
    AudioDeviceIOProcID proc;
    bool running;
    uint32_t buffer_frames;
    uint32_t latency_frames;

    // ---- recording: IO thread produces, writer thread consumes
    _Atomic bool recording;
    _Atomic bool rec_stop;
    _Atomic uint64_t ring_w, ring_r;
    _Atomic uint32_t rec_overflows;
    _Atomic uint64_t recorded_frames;
    _Atomic double rec_origin;   // host time of the recording's first frame
    int rec_tracks;
    float *ring;
    pthread_t rec_thread;
    bool rec_thread_live;
    ExtAudioFileRef files[REC_TRACKS];

    mx_post_hook hook;
    void *hook_ctx;

    // ---- Jammer on inputs 1 and 2 (jammer_link.h)
    jammer_link *link;        // mapped once by the UI thread, never unmapped
    _Atomic bool link_on;
    _Atomic bool link_alive;  // IO thread: Jammer has written recently
    uint64_t link_timeout;    // mach ticks without a write before it's gone
    uint64_t link_rd;         // IO thread only
    bool link_synced;
};

static mx_channel_settings default_settings(void) {
    mx_channel_settings s = {
        .hpf_on = false, .hpf_hz = 80,
        .eq_on = false,
        .low_db = 0, .low_hz = 120,
        .mid_db = 0, .mid_hz = 1000, .mid_q = 1,
        .high_db = 0, .high_hz = 8000,
        .comp_on = false,
        .comp_threshold_db = -18, .comp_ratio = 3, .comp_makeup_db = 0,
        .comp_attack_ms = 10, .comp_release_ms = 150,
    };
    return s;
}

static void apply_settings(mx_engine *e, int c, const mx_channel_settings *s) {
    channel_rt *r = &e->ch[c];
    bool was_hpf = r->s.hpf_on, was_eq = r->s.eq_on;
    biquad old[BQ_COUNT];
    memcpy(old, r->bq, sizeof old);
    design_filters(r->bq, s, e->fs);
    // keep filter memory across coefficient changes to avoid clicks, but
    // start clean when a section is switched on
    for (int i = 0; i < BQ_COUNT; i++) {
        bool fresh = (i == BQ_HPF) ? (s->hpf_on && !was_hpf) : (s->eq_on && !was_eq);
        biquad *q = &r->bq[i], *qr = &r->bq_r[i];
        double z1r = fresh ? 0 : qr->z1, z2r = fresh ? 0 : qr->z2;
        q->z1 = fresh ? 0 : old[i].z1;
        q->z2 = fresh ? 0 : old[i].z2;
        *qr = *q;
        qr->z1 = z1r;
        qr->z2 = z2r;
    }
    double att = fmax(0.05, s->comp_attack_ms), rel = fmax(1, s->comp_release_ms);
    r->att_coef = (float)exp(-1.0 / (e->fs * att / 1000));
    r->rel_coef = (float)exp(-1.0 / (e->fs * rel / 1000));
    r->inv_ratio = 1.0f / fmaxf(1.0f, s->comp_ratio);
    r->s = *s;
}

static int delay_frames(mx_engine *e, int m) {
    double ms = atomic_load_explicit(&e->delay_ms[m], memory_order_relaxed);
    if (!(ms > 0)) return 0;
    if (ms > MX_MAX_DELAY_MS) ms = MX_MAX_DELAY_MS;
    int n = (int)lround(ms * e->fs / 1000);
    return n < DELAY_FRAMES - 1 ? n : DELAY_FRAMES - 1;
}

// Center is exactly unity on both sides, so an unpanned stereo mix is
// bit-identical to a mono one, and a hard pan is exactly silent on the other.
static void pan_gains(float p, float *l, float *r) {
    if (p == 0) { *l = *r = 1; return; }
    if (fabsf(p) >= 1) { *l = p < 0 ? (float)M_SQRT2 : 0; *r = p < 0 ? 0 : (float)M_SQRT2; return; }
    float a = (fminf(1, fmaxf(-1, p)) + 1) * (float)M_PI / 4;
    *l = (float)M_SQRT2 * cosf(a);
    *r = (float)M_SQRT2 * sinf(a);
}

// Each input's send to each mix as left and right gains: panned in a stereo
// mix, all on the left (its only side) in a mono one.
static void send_targets(mx_engine *e, float l[MX_MIXES][MX_CHANNELS],
                         float r[MX_MIXES][MX_CHANNELS]) {
    for (int m = 0; m < MX_MIXES; m++) {
        bool stereo = (m & 1) == 0 && e->link_cur[m / 2];
        for (int c = 0; c < MX_CHANNELS; c++) {
            float g = atomic_load_explicit(&e->send[m][c], memory_order_relaxed), pl = 1, pr = 0;
            if (stereo) pan_gains(atomic_load_explicit(&e->pan[m][c], memory_order_relaxed), &pl, &pr);
            l[m][c] = g * pl;
            r[m][c] = g * pr;
        }
    }
}

static void reset_rt(mx_engine *e, double fs) {
    e->fs = fs;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    e->ticks_per_frame = 1e9 * tb.denom / tb.numer / fs;
    e->smooth = (float)(1 - exp(-1.0 / (0.005 * fs)));  // ~5 ms glide
    e->lim_rel = (float)(1 - exp(-1.0 / (LIMIT_RELEASE_MS / 1000.0 * fs)));
    for (int c = 0; c < STRIPS; c++) {
        mx_channel_settings s = e->pending[c];
        memset(&e->ch[c], 0, sizeof e->ch[c]);
        e->ch[c].s = default_settings();
        apply_settings(e, c, &s);
        e->applied_seq[c] = atomic_load(&e->seq[c]);
        e->ch[c].mute_gain = atomic_load(&e->muted[c]) ? 0 : 1;
    }
    for (int p = 0; p < MX_PAIRS; p++) {
        e->link_cur[p] = atomic_load(&e->linked[p]);
        e->pair_gain[p] = 1;
        memset(&e->delay_r[p], 0, sizeof e->delay_r[p]);
        e->delay_r[p].cur = delay_frames(e, 2 * p);
    }
    for (int m = 0; m < MX_MIXES; m++) {
        memset(&e->delay[m], 0, sizeof e->delay[m]);
        e->delay[m].cur = delay_frames(e, m);
        e->master_g[m] = atomic_load(&e->master[m]);
        e->lim_g[m] = 1;
    }
    send_targets(e, e->send_l, e->send_r);
    e->last_in_time = -1;
    e->link_synced = false;
}

mx_engine *mx_engine_create(void) {
    mx_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->ring = calloc((size_t)RING_FRAMES * REC_TRACKS, sizeof(float));
    if (!e->ring) { free(e); return NULL; }
    for (int c = 0; c < STRIPS; c++) e->pending[c] = default_settings();
    atomic_store(&e->linked[0], true);   // Main on outs 1 and 2
    memset(e->scope, 0, sizeof e->scope);   // touch it now, not on the IO thread
    reset_rt(e, 48000);
    return e;
}

void mx_engine_destroy(mx_engine *e) {
    if (!e) return;
    mx_engine_record_stop(e);
    mx_engine_stop(e);
    free(e->ring);
    free(e);
}

static void set_strip(mx_engine *e, int c, const mx_channel_settings *s) {
    uint32_t v = atomic_load_explicit(&e->seq[c], memory_order_relaxed) + 1;
    atomic_store_explicit(&e->seq[c], v, memory_order_relaxed);  // odd: writing
    atomic_thread_fence(memory_order_release);
    e->pending[c] = *s;
    atomic_store_explicit(&e->seq[c], v + 1, memory_order_release);
}

void mx_engine_set_channel(mx_engine *e, int c, const mx_channel_settings *s) {
    if (c >= 0 && c < MX_CHANNELS) set_strip(e, c, s);
}
void mx_engine_set_mix_processing(mx_engine *e, int m, const mx_channel_settings *s) {
    if (m >= 0 && m < MX_MIXES) set_strip(e, MX_CHANNELS + m, s);
}

void mx_engine_set_send(mx_engine *e, int m, int c, float g) {
    if (m >= 0 && m < MX_MIXES && c >= 0 && c < MX_CHANNELS) atomic_store(&e->send[m][c], g);
}
void mx_engine_set_master(mx_engine *e, int m, float g) {
    if (m >= 0 && m < MX_MIXES) atomic_store(&e->master[m], g);
}
void mx_engine_set_mute(mx_engine *e, int c, bool muted) {
    if (c >= 0 && c < MX_CHANNELS) atomic_store(&e->muted[c], muted);
}
void mx_engine_set_mix_mute(mx_engine *e, int m, bool muted) {
    if (m >= 0 && m < MX_MIXES) atomic_store(&e->muted[MX_CHANNELS + m], muted);
}
void mx_engine_set_mix_delay(mx_engine *e, int m, float ms) {
    if (m >= 0 && m < MX_MIXES) atomic_store(&e->delay_ms[m], ms);
}

void mx_engine_set_linked(mx_engine *e, int p, bool on) {
    if (p >= 0 && p < MX_PAIRS) atomic_store(&e->linked[p], on);
}
void mx_engine_set_pan(mx_engine *e, int m, int c, float pan) {
    if (m >= 0 && m < MX_MIXES && c >= 0 && c < MX_CHANNELS) atomic_store(&e->pan[m][c], pan);
}
void mx_engine_set_mix_limit(mx_engine *e, int m, float db) {
    if (m >= 0 && m < MX_MIXES) atomic_store(&e->limit_db[m], db);
}

void mx_engine_set_post_hook(mx_engine *e, mx_post_hook hook, void *ctx) {
    e->hook = hook;
    e->hook_ctx = ctx;
}

static void pick_up_settings(mx_engine *e) {
    for (int c = 0; c < STRIPS; c++) {
        uint32_t s1 = atomic_load_explicit(&e->seq[c], memory_order_acquire);
        if (s1 == e->applied_seq[c] || (s1 & 1)) continue;
        mx_channel_settings tmp = e->pending[c];
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&e->seq[c], memory_order_relaxed) != s1) continue;
        apply_settings(e, c, &tmp);
        e->applied_seq[c] = s1;
    }
}

static inline void peak_max(_Atomic float *slot, float v) {
    if (v > atomic_load_explicit(slot, memory_order_relaxed))
        atomic_store_explicit(slot, v, memory_order_relaxed);
}

static void record_block(mx_engine *e, const float *in, int in_stride, int frames) {
    uint64_t w = atomic_load_explicit(&e->ring_w, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&e->ring_r, memory_order_acquire);
    uint64_t space = RING_FRAMES - (w - r);
    int n = frames <= (int)space ? frames : (int)space;
    for (int i = 0; i < n; i++) {
        float *dst = &e->ring[((w + i) & (RING_FRAMES - 1)) * REC_TRACKS];
        for (int c = 0; c < MX_CHANNELS; c++) dst[c] = in[i * in_stride + c];
        for (int j = 0; j < 2; j++) dst[MX_CHANNELS + j] = e->jacks ? e->jacks[i * 2 + j] : dst[j];
    }
    if (e->in_host > 0)
        atomic_store_explicit(&e->rec_origin, e->in_host - (double)w * e->ticks_per_frame,
                              memory_order_relaxed);
    atomic_store_explicit(&e->ring_w, w + n, memory_order_release);
    if (n < frames) atomic_fetch_add(&e->rec_overflows, 1);
}

static inline float run_filters(biquad *bq, const mx_channel_settings *s, float x) {
    if (s->hpf_on) x = bq_run(&bq[BQ_HPF], x);
    if (s->eq_on) {
        x = bq_run(&bq[BQ_LOW], x);
        x = bq_run(&bq[BQ_MID], x);
        x = bq_run(&bq[BQ_HIGH], x);
    }
    return x;
}

// Compressor gain, linear, for a detector level.
static inline float comp_gain(channel_rt *r, float lvl, float *grmax) {
    float coef = lvl > r->env ? r->att_coef : r->rel_coef;
    r->env = lvl + coef * (r->env - lvl);
    float over = 20.f * log10f(r->env + 1e-9f) - r->s.comp_threshold_db;
    float gr = over > 0 ? over * (1.f - r->inv_ratio) : 0.f;
    if (gr > *grmax) *grmax = gr;
    return powf(10.f, (r->s.comp_makeup_db - gr) * 0.05f);
}

// High-pass, EQ and compressor; mute is applied by the caller.
static inline float run_strip(channel_rt *r, float x, float *grmax) {
    x = run_filters(r->bq, &r->s, x);
    if (r->s.comp_on) x *= comp_gain(r, fabsf(x), grmax);
    return x;
}

// The same for a stereo mix.  Both sides are compressed together, from the
// louder one, so the image doesn't shift.
static inline void run_strip_stereo(channel_rt *r, float *l, float *rt, float *grmax) {
    *l = run_filters(r->bq, &r->s, *l);
    *rt = run_filters(r->bq_r, &r->s, *rt);
    if (r->s.comp_on) {
        float g = comp_gain(r, fmaxf(fabsf(*l), fabsf(*rt)), grmax);
        *l *= g;
        *rt *= g;
    }
}

void mx_engine_process(mx_engine *e, const float *in, int in_stride, float *out,
                       int out_stride, int frames) {
    pick_up_settings(e);

    // A pair whose linking changed fades out, switches, and fades back in.
    float pair_t[MX_PAIRS];
    for (int p = 0; p < MX_PAIRS; p++) {
        bool want = atomic_load_explicit(&e->linked[p], memory_order_relaxed);
        if (want != e->link_cur[p] && e->pair_gain[p] < 1e-3f) e->link_cur[p] = want;
        pair_t[p] = want == e->link_cur[p] ? 1.f : 0.f;
    }

    float mute_t[STRIPS], sl_t[MX_MIXES][MX_CHANNELS], sr_t[MX_MIXES][MX_CHANNELS];
    float master_t[MX_MIXES], ceiling[MX_MIXES];
    int delay_t[MX_MIXES];
    for (int c = 0; c < STRIPS; c++)
        mute_t[c] = atomic_load_explicit(&e->muted[c], memory_order_relaxed) ? 0.f : 1.f;
    for (int m = 0; m < MX_MIXES; m++) {
        master_t[m] = atomic_load_explicit(&e->master[m], memory_order_relaxed);
        delay_t[m] = delay_frames(e, m);
        float db = atomic_load_explicit(&e->limit_db[m], memory_order_relaxed);
        ceiling[m] = db < 0 ? powf(10.f, db * 0.05f) : 1.f;
    }
    send_targets(e, sl_t, sr_t);

    if (atomic_load_explicit(&e->recording, memory_order_relaxed))
        record_block(e, in, in_stride, frames);

    const float k = e->smooth;
    float inpk[MX_CHANNELS] = {0}, grmax[STRIPS] = {0}, mixinpk[MX_MIXES] = {0},
          mixpk[MX_MIXES] = {0}, limmin[MX_MIXES], outpk[MX_OUTPUTS] = {0};
    for (int m = 0; m < MX_MIXES; m++) limmin[m] = 1;
    uint32_t sw = atomic_load_explicit(&e->scope_w, memory_order_relaxed);

    for (int i = 0; i < frames; i++) {
        float y[MX_CHANNELS];
        float *scope = e->scope[(sw + i) & (MX_SCOPE_FRAMES - 1)];
        for (int c = 0; c < MX_CHANNELS; c++) {
            channel_rt *r = &e->ch[c];
            float x = in[i * in_stride + c];
            scope[c] = x;
            float a = fabsf(x);
            if (a > inpk[c]) inpk[c] = a;
            x = run_strip(r, x, &grmax[c]);
            r->mute_gain += k * (mute_t[c] - r->mute_gain);
            y[c] = x * r->mute_gain;
        }

        for (int p = 0; p < MX_PAIRS; p++) e->pair_gain[p] += k * (pair_t[p] - e->pair_gain[p]);
        float *o = &out[i * out_stride];

        for (int m = 0; m < MX_MIXES; m++) {
            int st = MX_CHANNELS + m, p = m / 2;
            bool even = (m & 1) == 0, stereo = even && e->link_cur[p];
            channel_rt *r = &e->ch[st];
            float l = 0, rt = 0;
            for (int c = 0; c < MX_CHANNELS; c++) {
                e->send_l[m][c] += k * (sl_t[m][c] - e->send_l[m][c]);
                e->send_r[m][c] += k * (sr_t[m][c] - e->send_r[m][c]);
                l += y[c] * e->send_l[m][c];
                rt += y[c] * e->send_r[m][c];
            }
            if (!stereo) rt = 0;
            scope[st] = stereo ? 0.5f * (l + rt) : l;
            float ai = fmaxf(fabsf(l), fabsf(rt));
            if (ai > mixinpk[m]) mixinpk[m] = ai;
            if (stereo) run_strip_stereo(r, &l, &rt, &grmax[st]);
            else l = run_strip(r, l, &grmax[st]);
            r->mute_gain += k * (mute_t[st] - r->mute_gain);
            e->master_g[m] += k * (master_t[m] - e->master_g[m]);
            float g = r->mute_gain * e->master_g[m];
            l = delay_run(&e->delay[m], l * g, delay_t[m]);
            // Runs while mono too, on silence, so relinking doesn't replay
            // old audio.
            if (even) rt = delay_run(&e->delay_r[p], rt * g, delay_t[m]);

            // Limiter: instant attack, so the output never passes the ceiling.
            float lvl = fmaxf(fabsf(l), fabsf(rt));
            float lg = e->lim_g[m] + e->lim_rel * (1.f - e->lim_g[m]);
            if (lvl * lg > ceiling[m]) lg = ceiling[m] / lvl;
            e->lim_g[m] = lg;
            if (lg < limmin[m]) limmin[m] = lg;
            l *= lg;
            rt *= lg;
            float a = fmaxf(fabsf(l), fabsf(rt));
            if (a > mixpk[m]) mixpk[m] = a;

            float pg = e->pair_gain[p];
            if (stereo) {
                o[m] = l * pg;
                o[m + 1] = rt * pg;
            } else if (!e->link_cur[p]) {
                o[m] = l * pg;
            }
        }
        for (int j = 0; j < MX_OUTPUTS; j++) {
            float a = fabsf(o[j]);
            if (a > outpk[j]) outpk[j] = a;
        }
    }

    atomic_store_explicit(&e->scope_w, sw + (uint32_t)frames, memory_order_release);
    for (int c = 0; c < MX_CHANNELS; c++) peak_max(&e->in_peak[c], inpk[c]);
    for (int c = 0; c < STRIPS; c++)
        atomic_store_explicit(&e->gr_db[c], e->ch[c].s.comp_on ? grmax[c] : 0.f,
                              memory_order_relaxed);
    for (int m = 0; m < MX_MIXES; m++) {
        peak_max(&e->mix_in_peak[m], mixinpk[m]);
        peak_max(&e->mix_peak[m], mixpk[m]);
        peak_max(&e->limit_gr[m], -20.f * log10f(limmin[m]));
    }
    for (int j = 0; j < MX_OUTPUTS; j++) peak_max(&e->out_peak[j], outpk[j]);

    if (e->hook) e->hook(e->hook_ctx, out, out_stride, frames);
}

void mx_engine_prepare_offline(mx_engine *e, double fs) { reset_rt(e, fs); }

void mx_engine_read_meters(mx_engine *e, mx_meters *out) {
    for (int c = 0; c < MX_CHANNELS; c++) {
        out->in_peak[c] = atomic_exchange(&e->in_peak[c], 0.f);
        out->gr_db[c] = atomic_load(&e->gr_db[c]);
    }
    for (int m = 0; m < MX_MIXES; m++) {
        out->mix_in_peak[m] = atomic_exchange(&e->mix_in_peak[m], 0.f);
        out->mix_gr_db[m] = atomic_load(&e->gr_db[MX_CHANNELS + m]);
        out->mix_peak[m] = atomic_exchange(&e->mix_peak[m], 0.f);
        out->limit_gr_db[m] = atomic_exchange(&e->limit_gr[m], 0.f);
    }
    for (int j = 0; j < MX_OUTPUTS; j++) out->out_peak[j] = atomic_exchange(&e->out_peak[j], 0.f);
}

void mx_engine_read_scope(mx_engine *e, int source, float out[MX_SCOPE_FRAMES]) {
    if (source < 0 || source >= STRIPS) {
        memset(out, 0, sizeof(float) * MX_SCOPE_FRAMES);
        return;
    }
    uint32_t w = atomic_load_explicit(&e->scope_w, memory_order_acquire);
    for (int i = 0; i < MX_SCOPE_FRAMES; i++)
        out[i] = e->scope[(w + i) & (MX_SCOPE_FRAMES - 1)][source];
}

// ---------------------------------------------------------------- device IO

// Find where logical channel `want` lives in a buffer list.
static float *locate(const AudioBufferList *l, int want, int *stride) {
    for (UInt32 b = 0; b < l->mNumberBuffers; b++) {
        int nc = (int)l->mBuffers[b].mNumberChannels;
        if (want < nc) {
            *stride = nc;
            return (float *)l->mBuffers[b].mData + want;
        }
        want -= nc;
    }
    return NULL;
}

// Jammer's left and right into channels 0 and 1 of interleaved `dst`.  Both
// apps run off the box's clock, so the ring doesn't drift; this stays a
// little behind Jammer's writes, by its block plus two of ours, and only
// jumps (a click) if the two threads' timing gets far enough apart to need
// it.  Silence while Jammer isn't writing.
static void link_read(mx_engine *e, float *dst, int frames) {
    jammer_link *l = e->link;
    uint64_t w = atomic_load_explicit(&l->write_pos, memory_order_acquire);
    uint64_t beat = atomic_load_explicit(&l->heartbeat, memory_order_relaxed);
    bool alive = beat != 0 && mach_absolute_time() - beat < e->link_timeout;
    atomic_store_explicit(&e->link_alive, alive, memory_order_relaxed);
    if (alive) {
        int64_t lag = (int64_t)(w - e->link_rd);
        if (!e->link_synced || lag < frames || lag > (int64_t)JL_FRAMES / 2) {
            uint32_t block = atomic_load_explicit(&l->block, memory_order_relaxed);
            if (block > JL_FRAMES / 4) block = JL_FRAMES / 4;
            uint64_t target = block + 2 * (uint64_t)frames;
            e->link_synced = w >= target;
            e->link_rd = w - target;
        }
    } else {
        e->link_synced = false;
    }
    for (int i = 0; i < frames; i++) {
        const float *f = l->audio[(e->link_rd + i) & (JL_FRAMES - 1)];
        dst[i * MX_CHANNELS] = e->link_synced ? f[0] : 0;
        dst[i * MX_CHANNELS + 1] = e->link_synced ? f[1] : 0;
    }
    if (e->link_synced) e->link_rd += frames;
}

static jammer_link *link_map(void) {
    int fd = shm_open(JL_NAME, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return NULL;
    // Whichever app gets here first sizes it; it can only be sized once.
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size == 0) ftruncate(fd, sizeof(jammer_link));
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(jammer_link)) {
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, sizeof(jammer_link), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;
    jammer_link *l = p;
    uint32_t expected = 0;
    atomic_compare_exchange_strong(&l->magic, &expected, JL_MAGIC);
    if (atomic_load(&l->magic) != JL_MAGIC) {
        munmap(p, sizeof(jammer_link));
        return NULL;
    }
    return l;
}

bool mx_engine_set_jammer_link(mx_engine *e, bool on) {
    if (on && !e->link) {
        e->link = link_map();
        if (!e->link) return false;
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        e->link_timeout = 100000000ull * tb.denom / tb.numer;   // 100 ms
    }
    atomic_store_explicit(&e->link_on, on, memory_order_release);
    if (!on) atomic_store(&e->link_alive, false);
    return true;
}

static OSStatus io_proc(AudioObjectID dev, const AudioTimeStamp *now,
                        const AudioBufferList *in, const AudioTimeStamp *in_time,
                        AudioBufferList *out, const AudioTimeStamp *out_time,
                        void *ctx) {
    mx_engine *e = ctx;
    atomic_fetch_add_explicit(&e->callbacks, 1, memory_order_relaxed);
    for (UInt32 b = 0; b < out->mNumberBuffers; b++)
        memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    if (out->mNumberBuffers == 0 || in->mNumberBuffers == 0) return noErr;

    int frames = (int)(out->mBuffers[0].mDataByteSize /
                       (sizeof(float) * out->mBuffers[0].mNumberChannels));
    if (frames > MAX_FRAMES) frames = MAX_FRAMES;

    if (e->last_in_time >= 0 && in_time->mSampleTime - e->last_in_time != frames)
        atomic_fetch_add_explicit(&e->dropouts, 1, memory_order_relaxed);
    e->last_in_time = in_time->mSampleTime;

    // The class driver normally hands us one interleaved buffer per
    // direction; anything else gets gathered into scratch space.
    const float *ip;
    int is;
    bool linked = atomic_load_explicit(&e->link_on, memory_order_acquire);
    e->in_host = (in_time->mFlags & kAudioTimeStampHostTimeValid) ? (double)in_time->mHostTime : 0;
    e->jacks = NULL;
    if (!linked && in->mNumberBuffers == 1 && in->mBuffers[0].mNumberChannels >= MX_CHANNELS) {
        ip = in->mBuffers[0].mData;
        is = (int)in->mBuffers[0].mNumberChannels;
    } else {
        for (int c = 0; c < MX_CHANNELS; c++) {
            int st;
            const float *p = locate(in, c, &st);
            for (int i = 0; i < frames; i++)
                e->in_scratch[i * MX_CHANNELS + c] = p ? p[i * st] : 0;
        }
        ip = e->in_scratch;
        is = MX_CHANNELS;
        if (linked) {
            for (int i = 0; i < frames; i++)
                for (int j = 0; j < 2; j++) e->jack_scratch[i * 2 + j] = e->in_scratch[i * MX_CHANNELS + j];
            e->jacks = e->jack_scratch;
            link_read(e, e->in_scratch, frames);
        }
    }

    if (out->mNumberBuffers == 1 && out->mBuffers[0].mNumberChannels >= MX_OUTPUTS) {
        mx_engine_process(e, ip, is, out->mBuffers[0].mData,
                          (int)out->mBuffers[0].mNumberChannels, frames);
    } else {
        memset(e->out_scratch, 0, sizeof(float) * frames * MX_OUTPUTS);
        mx_engine_process(e, ip, is, e->out_scratch, MX_OUTPUTS, frames);
        for (int c = 0; c < MX_OUTPUTS; c++) {
            int st;
            float *p = locate(out, c, &st);
            if (!p) continue;
            for (int i = 0; i < frames; i++) p[i * st] = e->out_scratch[i * MX_OUTPUTS + c];
        }
    }
    return noErr;
}

static OSStatus overload_listener(AudioObjectID o, UInt32 n,
                                  const AudioObjectPropertyAddress *a, void *ctx) {
    mx_engine *e = ctx;
    atomic_fetch_add(&e->dropouts, 1);
    return noErr;
}

static const AudioObjectPropertyAddress overload_addr = {
    kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain};

static UInt32 get_u32(AudioObjectID o, AudioObjectPropertySelector sel,
                      AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 v = 0, sz = sizeof v;
    AudioObjectGetPropertyData(o, &a, 0, NULL, &sz, &v);
    return v;
}

static int channel_count(AudioObjectID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, scope,
                                    kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) || sz == 0) return 0;
    AudioBufferList *l = malloc(sz);
    int n = 0;
    if (l && !AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, l))
        for (UInt32 b = 0; b < l->mNumberBuffers; b++) n += (int)l->mBuffers[b].mNumberChannels;
    free(l);
    return n;
}

static void cfstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) {
        CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(s);
    }
}

static void device_strings(AudioObjectID dev, char *name, size_t nn, char *uid, size_t un) {
    AudioObjectPropertyAddress a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    CFStringRef s = NULL;
    UInt32 sz = sizeof s;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &s)) s = NULL;
    cfstr(s, name, nn);
    a.mSelector = kAudioDevicePropertyDeviceUID;
    s = NULL;
    sz = sizeof s;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &s)) s = NULL;
    cfstr(s, uid, un);
}

int mx_list_devices(mx_device_info *out, int max) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz)) return 0;
    int n = (int)(sz / sizeof(AudioObjectID)), found = 0;
    AudioObjectID *ids = malloc(sz);
    if (!ids) return 0;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    for (int i = 0; i < n && found < max; i++) {
        int ins = channel_count(ids[i], kAudioObjectPropertyScopeInput);
        int outs = channel_count(ids[i], kAudioObjectPropertyScopeOutput);
        if (ins < MX_CHANNELS || outs < MX_OUTPUTS) continue;
        mx_device_info *d = &out[found++];
        device_strings(ids[i], d->name, sizeof d->name, d->uid, sizeof d->uid);
        d->inputs = ins;
        d->outputs = outs;
    }
    free(ids);
    return found;
}

static AudioObjectID find_device(const char *uid) {
    mx_device_info list[32];
    int n = mx_list_devices(list, 32);
    const char *want = NULL;
    for (int i = 0; i < n && !want; i++)
        if (uid && uid[0] && strcmp(list[i].uid, uid) == 0) want = list[i].uid;
    for (int i = 0; i < n && !want; i++)
        if ((!uid || !uid[0]) && strstr(list[i].name, "1818")) want = list[i].uid;
    if (!want && (!uid || !uid[0]) && n > 0) want = list[0].uid;
    if (!want) return kAudioObjectUnknown;

    CFStringRef s = CFStringCreateWithCString(NULL, want, kCFStringEncodingUTF8);
    AudioObjectID dev = kAudioObjectUnknown;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 sz = sizeof dev;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof s, &s, &sz, &dev);
    CFRelease(s);
    return dev;
}

static uint32_t estimate_latency(AudioObjectID dev, uint32_t buf) {
    uint32_t total = 2 * buf;
    AudioObjectPropertyScope scopes[2] = {kAudioObjectPropertyScopeInput,
                                          kAudioObjectPropertyScopeOutput};
    for (int i = 0; i < 2; i++) {
        total += get_u32(dev, kAudioDevicePropertyLatency, scopes[i]);
        total += get_u32(dev, kAudioDevicePropertySafetyOffset, scopes[i]);
        AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, scopes[i],
                                        kAudioObjectPropertyElementMain};
        AudioObjectID streams[8];
        UInt32 sz = sizeof streams;
        if (!AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, streams) && sz >= sizeof(AudioObjectID))
            total += get_u32(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
    }
    return total;
}

int mx_engine_start(mx_engine *e, const char *uid, double rate, uint32_t buf) {
    if (e->running) return MX_ERR_ALREADY;
    AudioObjectID dev = find_device(uid);
    if (dev == kAudioObjectUnknown) return MX_ERR_NO_DEVICE;
    if (channel_count(dev, kAudioObjectPropertyScopeInput) < MX_CHANNELS ||
        channel_count(dev, kAudioObjectPropertyScopeOutput) < MX_OUTPUTS)
        return MX_ERR_TOO_FEW_CHANNELS;

    AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate,
                                     kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float64 cur = 0;
    UInt32 sz = sizeof cur;
    AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &cur);
    if (cur != rate) {
        OSStatus err = AudioObjectSetPropertyData(dev, &ra, 0, NULL, sizeof rate, &rate);
        if (err) return (int)err;
        for (int i = 0; i < 40 && cur != rate; i++) {  // the change is asynchronous
            usleep(50000);
            sz = sizeof cur;
            AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &cur);
        }
    }

    AudioObjectPropertyAddress ba = {kAudioDevicePropertyBufferFrameSize,
                                     kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 b = buf;
    AudioObjectSetPropertyData(dev, &ba, 0, NULL, sizeof b, &b);
    e->buffer_frames = get_u32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    e->latency_frames = estimate_latency(dev, e->buffer_frames);

    reset_rt(e, cur);
    e->device = dev;
    OSStatus err = AudioDeviceCreateIOProcID(dev, io_proc, e, &e->proc);
    if (err) return (int)err;
    AudioObjectAddPropertyListener(dev, &overload_addr, overload_listener, e);
    err = AudioDeviceStart(dev, e->proc);
    if (err) {
        AudioObjectRemovePropertyListener(dev, &overload_addr, overload_listener, e);
        AudioDeviceDestroyIOProcID(dev, e->proc);
        return (int)err;
    }
    e->running = true;
    return 0;
}

void mx_engine_stop(mx_engine *e) {
    if (!e->running) return;
    AudioDeviceStop(e->device, e->proc);
    AudioDeviceDestroyIOProcID(e->device, e->proc);
    AudioObjectRemovePropertyListener(e->device, &overload_addr, overload_listener, e);
    e->running = false;
}

void mx_engine_get_stats(mx_engine *e, mx_stats *st) {
    memset(st, 0, sizeof *st);
    st->running = e->running;
    if (e->running) {
        st->alive = get_u32(e->device, kAudioDevicePropertyDeviceIsAlive,
                            kAudioObjectPropertyScopeGlobal) != 0;
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate,
                                         kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        Float64 r = 0;
        UInt32 sz = sizeof r;
        AudioObjectGetPropertyData(e->device, &ra, 0, NULL, &sz, &r);
        st->sample_rate = r;
    }
    st->buffer_frames = e->buffer_frames;
    st->latency_frames = e->latency_frames;
    st->callbacks = atomic_load(&e->callbacks);
    st->dropouts = atomic_load(&e->dropouts);
    st->recording = atomic_load(&e->recording);
    st->recorded_frames = atomic_load(&e->recorded_frames);
    st->record_overflows = atomic_load(&e->rec_overflows);
    st->jammer_linked = atomic_load(&e->link_on);
    st->jammer_alive = st->jammer_linked && st->running && atomic_load(&e->link_alive);
}

// ---------------------------------------------------------------- recording

static void *rec_main(void *arg) {
    mx_engine *e = arg;
    static float planes[REC_TRACKS][4096];
    for (;;) {
        uint64_t r = atomic_load_explicit(&e->ring_r, memory_order_relaxed);
        uint64_t w = atomic_load_explicit(&e->ring_w, memory_order_acquire);
        uint64_t avail = w - r;
        if (avail == 0) {
            if (atomic_load(&e->rec_stop)) break;
            usleep(20000);
            continue;
        }
        UInt32 n = avail > 4096 ? 4096 : (UInt32)avail;
        for (UInt32 i = 0; i < n; i++) {
            const float *src = &e->ring[((r + i) & (RING_FRAMES - 1)) * REC_TRACKS];
            for (int c = 0; c < e->rec_tracks; c++) planes[c][i] = src[c];
        }
        atomic_store_explicit(&e->ring_r, r + n, memory_order_release);
        for (int c = 0; c < e->rec_tracks; c++) {
            AudioBufferList l = {1, {{1, n * (UInt32)sizeof(float), planes[c]}}};
            ExtAudioFileWrite(e->files[c], n, &l);
        }
        atomic_fetch_add(&e->recorded_frames, n);
    }
    return NULL;
}

int mx_engine_record_start(mx_engine *e, const char *dir, bool jacks) {
    if (e->rec_thread_live) return MX_ERR_ALREADY;
    e->rec_tracks = jacks ? REC_TRACKS : MX_CHANNELS;
    double fs = e->fs;
    AudioStreamBasicDescription file = {
        .mSampleRate = fs, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 3, .mFramesPerPacket = 1, .mBytesPerFrame = 3,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 24};
    AudioStreamBasicDescription client = {
        .mSampleRate = fs, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 32};

    for (int c = 0; c < e->rec_tracks; c++) {
        char path[1024];
        if (c < MX_CHANNELS) snprintf(path, sizeof path, "%s/in%d.wav", dir, c + 1);
        else snprintf(path, sizeof path, "%s/jack%d.wav", dir, c - MX_CHANNELS + 1);
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(
            NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
        OSStatus err = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &file, NULL,
                                                 kAudioFileFlags_EraseFile, &e->files[c]);
        CFRelease(url);
        if (!err)
            err = ExtAudioFileSetProperty(e->files[c], kExtAudioFileProperty_ClientDataFormat,
                                          sizeof client, &client);
        if (err) {
            for (int j = 0; j <= c; j++) {
                if (e->files[j]) ExtAudioFileDispose(e->files[j]);
                e->files[j] = NULL;
            }
            return MX_ERR_FILE;
        }
    }

    atomic_store(&e->ring_r, 0);
    atomic_store(&e->ring_w, 0);
    atomic_store(&e->recorded_frames, 0);
    atomic_store(&e->rec_origin, 0);
    atomic_store(&e->rec_overflows, 0);
    atomic_store(&e->rec_stop, false);
    pthread_create(&e->rec_thread, NULL, rec_main, e);
    e->rec_thread_live = true;
    atomic_store(&e->recording, true);
    return 0;
}

void mx_engine_record_stop(mx_engine *e) {
    if (!e->rec_thread_live) return;
    atomic_store(&e->recording, false);
    atomic_store(&e->rec_stop, true);
    pthread_join(e->rec_thread, NULL);
    e->rec_thread_live = false;
    for (int c = 0; c < REC_TRACKS; c++) {
        if (e->files[c]) ExtAudioFileDispose(e->files[c]);
        e->files[c] = NULL;
    }
}

double mx_engine_record_origin(mx_engine *e) {
    return atomic_load_explicit(&e->rec_origin, memory_order_relaxed);
}

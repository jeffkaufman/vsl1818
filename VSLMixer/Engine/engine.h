// Real-time mixing engine for an 8-in / 8-out class-compliant interface.
//
// Everything that runs on the CoreAudio IO thread lives in C so it never
// allocates, locks, or touches the Swift runtime.  The UI thread hands
// settings over with lock-free writes; the IO thread picks them up at the
// start of each buffer.

#pragma once
#include <stdbool.h>
#include <stdint.h>

#define MX_CHANNELS 8
#define MX_MIXES 8     // mix m drives out m+1, except that by default mix 0
                       // (Main) drives outs 1 and 2 and mix 1 is unused
#define MX_OUTPUTS 8
#define MX_SCOPE_FRAMES 4096   // recent samples kept per source for spectra
#define MX_MAX_DELAY_MS 250    // per-output delay, for lining up with distant speakers

typedef struct {
    bool hpf_on;
    float hpf_hz;
    bool eq_on;
    float low_db, low_hz;
    float mid_db, mid_hz, mid_q;
    float high_db, high_hz;
    bool comp_on;
    float comp_threshold_db, comp_ratio, comp_makeup_db;
    float comp_attack_ms, comp_release_ms;
} mx_channel_settings;

typedef struct {
    char name[128];
    char uid[256];
    int inputs, outputs;
} mx_device_info;

typedef struct {
    bool running;            // IO proc installed and started
    bool alive;              // device still present
    double sample_rate;
    uint32_t buffer_frames;
    uint32_t latency_frames; // estimated analog round-trip through the mixer
    uint64_t callbacks;      // increments every IO cycle; stalls show up here
    uint32_t dropouts;       // overloads + timeline discontinuities
    bool recording;
    uint64_t recorded_frames;
    uint32_t record_overflows;
    bool jammer_linked;      // inputs 1 and 2 come from Jammer
    bool jammer_alive;       // and Jammer is playing into them
} mx_stats;

typedef struct mx_engine mx_engine;

mx_engine *mx_engine_create(void);
void mx_engine_destroy(mx_engine *e);

// Devices with at least 8 inputs and 8 outputs.  Returns the count.
int mx_list_devices(mx_device_info *out, int max);

// device_uid may be NULL or "" to pick an AudioBox 1818VSL, else the first
// 8x8 device.  Returns 0 on success, an OSStatus, or a negative mx error.
int mx_engine_start(mx_engine *e, const char *device_uid, double sample_rate,
                    uint32_t buffer_frames);
void mx_engine_stop(mx_engine *e);
void mx_engine_get_stats(mx_engine *e, mx_stats *stats);

void mx_engine_set_channel(mx_engine *e, int ch, const mx_channel_settings *s);
void mx_engine_set_send(mx_engine *e, int mix, int ch, float gain);
void mx_engine_set_master(mx_engine *e, int mix, float gain);
void mx_engine_set_mute(mx_engine *e, int ch, bool muted);
// A mix's own high-pass, EQ, compressor and mute, applied to its sum before
// the master gain.
void mx_engine_set_mix_processing(mx_engine *e, int mix, const mx_channel_settings *s);
void mx_engine_set_mix_mute(mx_engine *e, int mix, bool muted);
// Delays a mix's output, after its master.  Changes crossfade over ~5 ms.
void mx_engine_set_mix_delay(mx_engine *e, int mix, float ms);
// Takes inputs 1 and 2 from Jammer's main left and right instead of the
// jacks (see jammer_link.h).  Everything downstream, recording included,
// sees Jammer there.  False if the shared memory couldn't be opened.
bool mx_engine_set_jammer_link(mx_engine *e, bool on);
// Splits Main into two mono mixes: mix 0 on out 1 and mix 1 on out 2.  Off
// (the default), mix 0 drives both and mix 1 goes nowhere.
void mx_engine_set_split_main(mx_engine *e, bool on);

typedef struct {
    float in_peak[MX_CHANNELS];   // linear, before any processing
    float gr_db[MX_CHANNELS];     // current compressor gain reduction
    float mix_in_peak[MX_MIXES];  // linear, the sum before the mix's processing
    float mix_gr_db[MX_MIXES];
    float mix_peak[MX_MIXES];     // linear, what goes to the jacks
} mx_meters;

// Peaks since the previous call, and current gain reduction.
void mx_engine_read_meters(mx_engine *e, mx_meters *m);

// The latest MX_SCOPE_FRAMES samples, oldest first, of input `source`
// (0..MX_CHANNELS-1) or of mix `source - MX_CHANNELS`, both before any
// processing.  The oldest few may be torn by a concurrent IO cycle, which a
// windowed FFT doesn't notice.
void mx_engine_read_scope(mx_engine *e, int source, float out[MX_SCOPE_FRAMES]);

// Records the raw inputs as eight mono 24-bit WAV files in directory.
int mx_engine_record_start(mx_engine *e, const char *directory);
void mx_engine_record_stop(mx_engine *e);

// Magnitude response of the high-pass + EQ section, for drawing curves.
double mx_eq_response_db(const mx_channel_settings *s, double sample_rate,
                         double freq);

// For tests: run the mixer without a device.
void mx_engine_prepare_offline(mx_engine *e, double sample_rate);
void mx_engine_process(mx_engine *e, const float *in, int in_stride,
                       float *out, int out_stride, int frames);
typedef void (*mx_post_hook)(void *ctx, float *out, int out_stride, int frames);
void mx_engine_set_post_hook(mx_engine *e, mx_post_hook hook, void *ctx);

enum {
    MX_ERR_NO_DEVICE = -1,
    MX_ERR_TOO_FEW_CHANNELS = -2,
    MX_ERR_ALREADY = -3,
    MX_ERR_FILE = -4,
};

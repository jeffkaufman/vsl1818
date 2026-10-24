// End-to-end test through real hardware.  Needs an AudioBox 1818VSL with
// output N cabled to input N.
//
// A 1 kHz tone is injected on output 1, so it arrives on input 1.  The mixer
// sends input 1 only to aux 1 (output 3), which arrives on input 3, and
// nothing else is routed, so there is no feedback.  The mixer's own recorder
// captures the inputs and we compare input 3 to input 1 as processing changes.

#include "../Engine/engine.h"

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define TONE_HZ 1000.0

static double phase = 0, rate = 48000;
static int failures = 0;

static void inject(void *ctx, float *out, int stride, int frames) {
    for (int i = 0; i < frames; i++) {
        out[i * stride + 0] += 0.05f * (float)sin(phase);
        phase += 2 * M_PI * TONE_HZ / rate;
        if (phase > 2 * M_PI) phase -= 2 * M_PI;
    }
}

// Amplitude of the 1 kHz component over the last second of a recording, dBFS.
static double tone_level(const char *dir, int input) {
    char path[1024];
    snprintf(path, sizeof path, "%s/in%d.wav", dir, input);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path,
                                                           (CFIndex)strlen(path), false);
    ExtAudioFileRef f;
    if (ExtAudioFileOpenURL(url, &f)) { CFRelease(url); return NAN; }
    CFRelease(url);
    AudioStreamBasicDescription client = {
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 32};
    ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);
    SInt64 len = 0;
    UInt32 sz = sizeof len;
    ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileLengthFrames, &sz, &len);
    UInt32 n = (UInt32)rate;
    if (len < n) { ExtAudioFileDispose(f); return NAN; }
    ExtAudioFileSeek(f, len - n);
    float *buf = malloc(n * sizeof(float));
    AudioBufferList l = {1, {{1, n * (UInt32)sizeof(float), buf}}};
    ExtAudioFileRead(f, &n, &l);
    ExtAudioFileDispose(f);
    double re = 0, im = 0;
    for (UInt32 i = 0; i < n; i++) {
        re += buf[i] * cos(2 * M_PI * TONE_HZ * i / rate);
        im += buf[i] * sin(2 * M_PI * TONE_HZ * i / rate);
    }
    free(buf);
    return 20 * log10(2 * sqrt(re * re + im * im) / n + 1e-12);
}

// Record for a couple of seconds and return in3 relative to in1, in dB.
static double phase_gain(mx_engine *e, const char *root, const char *name, double *in1_db) {
    char dir[1024];
    snprintf(dir, sizeof dir, "%s/%s", root, name);
    mkdir(dir, 0755);
    usleep(300000);  // let gain changes and the compressor settle
    if (mx_engine_record_start(e, dir)) { printf("could not record to %s\n", dir); exit(2); }
    sleep(2);
    mx_engine_record_stop(e);
    double a = tone_level(dir, 1), b = tone_level(dir, 3);
    if (in1_db) *in1_db = a;
    return b - a;
}

static void check(const char *what, double got, double want, double tol) {
    bool ok = fabs(got - want) <= tol;
    printf("%s %-44s got %7.2f want %7.2f\n", ok ? "  ok  " : "FAIL  ", what, got, want);
    if (!ok) failures++;
}

static mx_channel_settings flat(void) {
    mx_channel_settings s = {0};
    s.hpf_hz = 80; s.low_hz = 120; s.mid_hz = 1000; s.mid_q = 1; s.high_hz = 8000;
    s.comp_threshold_db = -18; s.comp_ratio = 3; s.comp_attack_ms = 5; s.comp_release_ms = 100;
    return s;
}

int main(int argc, char **argv) {
    uint32_t buf = argc > 1 ? (uint32_t)atoi(argv[1]) : 32;
    char root[1024];
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/vslmixer-loopback-XXXXXX", tmp ? tmp : "/tmp");
    if (!mkdtemp(root)) return 2;

    mx_engine *e = mx_engine_create();
    mx_engine_set_send(e, 1, 0, 1);    // in1 -> aux 1 (out 3) at 0 dB
    mx_engine_set_master(e, 1, 1);
    mx_engine_set_post_hook(e, inject, NULL);
    int err = mx_engine_start(e, NULL, 48000, buf);
    if (err) { printf("could not start audio: %d\n", err); return 2; }
    mx_stats st;
    mx_engine_get_stats(e, &st);
    rate = st.sample_rate;
    printf("running at %.0f Hz, %u-frame buffer, estimated round-trip %.2f ms\n",
           st.sample_rate, st.buffer_frames, 1000.0 * st.latency_frames / st.sample_rate);

    double in1, base = phase_gain(e, root, "flat", &in1);
    printf("  input 1 tone at %.1f dBFS; flat analog path in1 -> in3 is %+.2f dB\n", in1, base);
    if (!(in1 > -40)) { printf("FAIL  no tone on input 1: check out1 -> in1 cable\n"); return 1; }

    mx_channel_settings s = flat();
    s.eq_on = true; s.mid_db = 6; s.mid_hz = 1000;
    mx_engine_set_channel(e, 0, &s);
    check("EQ +6 dB at 1 kHz", phase_gain(e, root, "eq", NULL) - base, 6, 0.3);

    s = flat();
    s.comp_on = true; s.comp_threshold_db = (float)(in1 - 12); s.comp_ratio = 4;
    mx_engine_set_channel(e, 0, &s);
    check("compressor 4:1, 12 dB over threshold", phase_gain(e, root, "comp", NULL) - base, -9, 0.6);

    s = flat();
    mx_engine_set_channel(e, 0, &s);
    mx_engine_set_send(e, 1, 0, 0.5f);
    check("send at -6 dB", phase_gain(e, root, "send", NULL) - base, -6.02, 0.3);

    mx_engine_set_mute(e, 0, true);
    double muted = phase_gain(e, root, "mute", NULL);
    printf("%s %-44s got %7.2f want < %5.1f\n", muted < -60 ? "  ok  " : "FAIL  ",
           "mute (in3 relative to in1)", muted, -60.0);
    if (muted >= -60) failures++;

    mx_engine_get_stats(e, &st);
    printf("%s %-44s got %7u want %7d\n", st.dropouts == 0 ? "  ok  " : "FAIL  ",
           "dropouts during test", st.dropouts, 0);
    if (st.dropouts) failures++;
    printf("%s %-44s got %7u want %7d\n", st.record_overflows == 0 ? "  ok  " : "FAIL  ",
           "recorder overflows", st.record_overflows, 0);
    if (st.record_overflows) failures++;

    mx_engine_destroy(e);
    if (failures) printf("\n%d FAILED (recordings in %s)\n", failures, root);
    else printf("\nall passed (recordings in %s)\n", root);
    return failures != 0;
}

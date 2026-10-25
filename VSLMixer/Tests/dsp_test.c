// Offline checks of the mixer's processing; no audio device needed.
// Build and run with Tests/run_tests.sh.

#include "../Engine/engine.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FS 48000
#define IN_CH 18
#define OUT_CH 18

static int failures = 0;

static void check(const char *what, double got, double want, double tol) {
    bool ok = fabs(got - want) <= tol;
    printf("%s %-48s got %8.3f want %8.3f\n", ok ? "  ok  " : "FAIL  ", what, got, want);
    if (!ok) failures++;
}

static mx_channel_settings flat(void) {
    mx_channel_settings s = {0};
    s.hpf_hz = 80; s.low_hz = 120; s.mid_hz = 1000; s.mid_q = 1; s.high_hz = 8000;
    s.comp_threshold_db = -18; s.comp_ratio = 3; s.comp_attack_ms = 10; s.comp_release_ms = 150;
    return s;
}

// Feed a sine into input `ch` for `secs` and return the peak of output `out`
// over the final 100 ms, in dBFS.
static double run_tone(mx_engine *e, int ch, double hz, double amp, double secs, int out) {
    int n = (int)(FS * secs), block = 64;
    float in[64 * IN_CH], o[64 * OUT_CH];
    double peak = 0;
    for (int start = 0; start < n; start += block) {
        memset(in, 0, sizeof in);
        memset(o, 0, sizeof o);
        for (int i = 0; i < block; i++)
            in[i * IN_CH + ch] = (float)(amp * sin(2 * M_PI * hz * (start + i) / FS));
        mx_engine_process(e, in, IN_CH, o, OUT_CH, block);
        if (start >= n - FS / 10)
            for (int i = 0; i < block; i++) peak = fmax(peak, fabs(o[i * OUT_CH + out]));
    }
    return 20 * log10(peak + 1e-12);
}

int main(void) {
    printf("EQ curve math\n");
    mx_channel_settings s = flat();
    s.hpf_on = true; s.hpf_hz = 100;
    check("high-pass at its corner (dB)", mx_eq_response_db(&s, FS, 100), -3.01, 0.05);
    check("high-pass one octave below (dB)", mx_eq_response_db(&s, FS, 50), -12.3, 0.3);
    check("high-pass passband 2 kHz (dB)", mx_eq_response_db(&s, FS, 2000), 0, 0.05);
    s = flat(); s.eq_on = true; s.mid_db = 6; s.mid_hz = 1000;
    check("mid peak +6 at center (dB)", mx_eq_response_db(&s, FS, 1000), 6, 0.05);
    check("mid peak far away (dB)", mx_eq_response_db(&s, FS, 50), 0, 0.2);
    s = flat(); s.eq_on = true; s.low_db = 6; s.low_hz = 100;
    check("low shelf +6 well below (dB)", mx_eq_response_db(&s, FS, 20), 6, 0.3);
    check("low shelf +6 at its frequency (dB)", mx_eq_response_db(&s, FS, 100), 3, 0.1);
    s = flat(); s.eq_on = true; s.high_db = -6; s.high_hz = 5000;
    check("high shelf -6 well above (dB)", mx_eq_response_db(&s, FS, 20000), -6, 0.4);

    printf("Routing\n");
    mx_engine *e = mx_engine_create();
    mx_engine_prepare_offline(e, FS);
    s = flat();
    mx_engine_set_channel(e, 0, &s);
    mx_engine_set_send(e, 0, 0, 1);
    mx_engine_set_master(e, 0, 1);
    double ref = 20 * log10(0.5);
    check("in1 -> main, out 1 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 0), ref, 0.05);
    check("in1 -> main, out 2 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 1), ref, 0.05);
    check("nothing on out 3 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 2), -240, 1);
    mx_engine_set_send(e, 3, 0, 0.5);
    mx_engine_set_master(e, 3, 1);
    check("in1 -> aux 3 at -6 dB, out 5 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), ref - 6.02, 0.05);
    check("channels past 8 untouched (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 9), -240, 1);

    printf("Processing\n");
    s.eq_on = true; s.mid_db = 6; s.mid_hz = 1000;
    mx_engine_set_channel(e, 0, &s);
    check("EQ +6 at 1 kHz applied to signal (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 0), ref + 6, 0.1);
    s = flat(); s.comp_on = true; s.comp_threshold_db = -20; s.comp_ratio = 4;
    s.comp_attack_ms = 1; s.comp_release_ms = 100;
    mx_engine_set_channel(e, 0, &s);
    // -10 dBFS in, 10 dB over threshold at 4:1 -> 7.5 dB of gain reduction
    check("compressor 4:1, 10 dB over (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 0), -17.5, 0.5);
    s.comp_makeup_db = 5;
    mx_engine_set_channel(e, 0, &s);
    mx_meters mt;
    mx_engine_read_meters(e, &mt);  // meters hold peaks since the last read
    check("compressor + 5 dB makeup (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 0), -12.5, 0.5);
    mx_engine_read_meters(e, &mt);
    check("gain-reduction meter (dB)", mt.gr_db[0], 7.5, 0.5);
    check("input peak meter (dBFS)", 20 * log10(mt.in_peak[0]), -10, 0.1);

    float scope[MX_SCOPE_FRAMES];
    mx_engine_read_scope(e, 0, scope);
    double spk = 0;
    for (int i = 0; i < MX_SCOPE_FRAMES; i++) spk = fmax(spk, fabs(scope[i]));
    check("scope holds the raw input (dBFS)", 20 * log10(spk), -10, 0.1);

    mx_engine_set_mute(e, 0, true);
    check("muted channel (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 0), -240, 1);
    check("muted in aux too (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), -240, 1);

    printf("Output processing\n");
    s = flat();
    mx_engine_set_channel(e, 0, &s);
    mx_engine_set_mute(e, 0, false);
    s.eq_on = true; s.mid_db = -6; s.mid_hz = 1000;
    mx_engine_set_mix_processing(e, 3, &s);
    check("aux 3 EQ -6 at 1 kHz (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), ref - 6.02 - 6, 0.1);
    check("main unaffected by aux EQ (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 0), ref, 0.05);
    s = flat(); s.comp_on = true; s.comp_threshold_db = -20; s.comp_ratio = 4;
    s.comp_attack_ms = 1; s.comp_release_ms = 100;
    mx_engine_set_mix_processing(e, 0, &s);
    mx_engine_read_meters(e, &mt);
    check("main compressor 4:1, 10 dB over (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 0), -17.5, 0.5);
    mx_engine_read_meters(e, &mt);
    check("main gain-reduction meter (dB)", mt.mix_gr_db[0], 7.5, 0.5);
    check("main pre-processing peak (dBFS)", 20 * log10(mt.mix_in_peak[0]), -10, 0.1);
    check("input has no gain reduction (dB)", mt.gr_db[0], 0, 0.01);
    mx_engine_read_scope(e, MX_CHANNELS + 0, scope);
    spk = 0;
    for (int i = 0; i < MX_SCOPE_FRAMES; i++) spk = fmax(spk, fabs(scope[i]));
    check("main scope is before its processing (dBFS)", 20 * log10(spk), -10, 0.1);
    mx_engine_set_mix_mute(e, 3, true);
    check("muted aux 3 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), -240, 1);
    check("main still plays (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 0), -17.5, 0.5);
    mx_engine_destroy(e);

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures != 0;
}

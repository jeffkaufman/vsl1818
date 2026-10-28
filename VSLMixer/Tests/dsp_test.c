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

// Let any delay crossfade settle, then send one impulse into input 1 and
// return how many samples later the biggest output sample appears on `out`.
static int impulse_lag(mx_engine *e, int out) {
    float in[64 * IN_CH], o[64 * OUT_CH];
    memset(in, 0, sizeof in);
    for (int i = 0; i < 20; i++) mx_engine_process(e, in, IN_CH, o, OUT_CH, 64);
    int best = -1, n = 0;
    double peak = 0;
    for (int blk = 0; blk < FS / 2 / 64; blk++) {
        memset(in, 0, sizeof in);
        if (blk == 0) in[0] = 1;
        mx_engine_process(e, in, IN_CH, o, OUT_CH, 64);
        for (int i = 0; i < 64; i++, n++)
            if (fabs(o[i * OUT_CH + out]) > peak) { peak = fabs(o[i * OUT_CH + out]); best = n; }
    }
    return best;
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
    mx_engine_set_send(e, 4, 0, 0.5);
    mx_engine_set_master(e, 4, 1);
    check("in1 -> aux 5 at -6 dB, out 5 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), ref - 6.02, 0.05);
    check("channels past 8 untouched (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 9), -240, 1);
    mx_engine_set_send(e, 1, 0, 0.5);
    mx_engine_set_master(e, 1, 1);
    check("aux 2 unused while main is paired (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 1), ref, 0.05);
    mx_engine_set_linked(e, 0, false);
    check("split: aux 1 on out 1 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 0), ref, 0.05);
    check("split: aux 2 on out 2 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 1), ref - 6.02, 0.05);
    mx_engine_set_linked(e, 0, true);
    mx_engine_set_send(e, 1, 0, 0);

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
    mx_engine_set_mix_processing(e, 4, &s);
    check("aux 5 EQ -6 at 1 kHz (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), ref - 6.02 - 6, 0.1);
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
    mx_engine_set_mix_mute(e, 4, true);
    check("muted aux 5 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 4), -240, 1);
    check("main still plays (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 0), -17.5, 0.5);

    printf("Output delay\n");
    s = flat();
    mx_engine_set_mix_processing(e, 0, &s);
    check("no delay: impulse on the same sample", impulse_lag(e, 0), 0, 0);
    mx_engine_set_mix_delay(e, 0, 10);
    check("10 ms delay at 48 kHz (samples)", impulse_lag(e, 0), 480, 0);
    mx_engine_set_mix_delay(e, 0, 1000);
    check("delay clamps to 250 ms (samples)", impulse_lag(e, 0), 12000, 0);
    mx_engine_set_mix_delay(e, 0, 0);
    check("back to no delay (samples)", impulse_lag(e, 0), 0, 0);

    printf("Stereo pairs\n");
    mx_engine_set_send(e, 0, 0, 0);
    mx_engine_set_mix_mute(e, 4, false);
    mx_engine_set_send(e, 2, 0, 1);
    mx_engine_set_master(e, 2, 1);
    mx_engine_set_send(e, 3, 0, 0.5);
    mx_engine_set_master(e, 3, 1);
    check("unlinked: aux 3 on out 3 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 2), ref, 0.05);
    check("unlinked: aux 4 on out 4 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 3), ref - 6.02, 0.05);
    mx_engine_set_linked(e, 1, true);
    check("3+4 linked, centered: out 3 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 2), ref, 0.05);
    check("3+4 linked, centered: out 4 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 3), ref, 0.05);
    mx_engine_set_pan(e, 2, 0, -1);
    check("hard left: +3 dB on out 3 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 2), ref + 3.01, 0.05);
    check("hard left: nothing on out 4 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 3), -240, 1);
    mx_engine_set_pan(e, 2, 0, 0.5);
    check("half right: out 3 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 2), ref - 5.33, 0.05);
    check("half right: out 4 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 3), ref + 2.33, 0.05);
    mx_engine_read_meters(e, &mt);
    run_tone(e, 0, 1000, 0.5, 0.5, 2);
    mx_engine_read_meters(e, &mt);
    check("out 3 meter (dBFS)", 20 * log10(mt.out_peak[2]), ref - 5.33, 0.05);
    check("out 4 meter (dBFS)", 20 * log10(mt.out_peak[3]), ref + 2.33, 0.05);
    check("stereo mix meter is the louder side (dBFS)", 20 * log10(mt.mix_peak[2]), ref + 2.33, 0.05);
    s = flat(); s.eq_on = true; s.mid_db = -6; s.mid_hz = 1000;
    mx_engine_set_mix_processing(e, 2, &s);
    check("stereo EQ on the left (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 2), ref - 5.33 - 6, 0.1);
    check("stereo EQ on the right (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 3), ref + 2.33 - 6, 0.1);
    s = flat(); s.comp_on = true; s.comp_threshold_db = -20; s.comp_ratio = 4;
    s.comp_attack_ms = 1; s.comp_release_ms = 100;
    mx_engine_set_mix_processing(e, 2, &s);
    // -10 dBFS in, half right: -7.67 on the right is 12.33 dB over, so 9.25 dB
    // of reduction, and the quieter left (-15.33) gets the same.
    check("linked compressor, right (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 3), -7.67 - 9.25, 0.5);
    check("linked compressor, left (dBFS)", run_tone(e, 0, 1000, pow(10, -0.5), 1.0, 2), -15.33 - 9.25, 0.5);
    mx_engine_set_mix_processing(e, 2, &(mx_channel_settings){0});
    mx_engine_set_pan(e, 2, 0, 0);
    mx_engine_set_mix_delay(e, 2, 10);
    check("stereo delay, left (samples)", impulse_lag(e, 2), 480, 0);
    check("stereo delay, right (samples)", impulse_lag(e, 3), 480, 0);
    mx_engine_set_mix_delay(e, 2, 0);
    impulse_lag(e, 2);
    mx_engine_set_linked(e, 1, false);
    check("unlinked again: aux 4 on out 4 (dBFS)", run_tone(e, 0, 1000, 0.5, 0.5, 3), ref - 6.02, 0.05);
    // The switch fades the pair down and up rather than jumping.
    {
        float in[64 * IN_CH], o[64 * OUT_CH];
        double biggest_step = 0, prev = 0;
        for (int start = 0; start < FS / 2; start += 64) {
            if (start == 64 * 200) mx_engine_set_linked(e, 1, true);
            memset(in, 0, sizeof in);
            for (int i = 0; i < 64; i++) in[i * IN_CH] = 0.5f;   // DC, so any jump is the switch
            mx_engine_process(e, in, IN_CH, o, OUT_CH, 64);
            for (int i = 0; i < 64; i++) {
                if (start >= FS / 8) biggest_step = fmax(biggest_step, fabs(o[i * OUT_CH + 3] - prev));
                prev = o[i * OUT_CH + 3];
            }
        }
        check("linking fades instead of jumping (step)", biggest_step < 0.02 ? 0 : biggest_step, 0, 0);
        check("and ends up linked (out 4)", prev, 0.5, 0.001);
    }
    mx_engine_set_linked(e, 1, false);
    mx_engine_set_send(e, 2, 0, 0);
    mx_engine_set_send(e, 3, 0, 0);

    printf("Limiter\n");
    mx_engine_set_mix_processing(e, 4, &(mx_channel_settings){0});
    mx_engine_set_send(e, 4, 0, 1);
    mx_engine_set_send(e, 5, 0, 1);
    mx_engine_set_master(e, 5, 1);
    check("no limit by default, -3 dBFS passes (dBFS)", run_tone(e, 0, 1000, pow(10, -3 / 20.0), 0.5, 4), -3, 0.05);
    mx_engine_set_mix_limit(e, 4, -6);
    mx_engine_read_meters(e, &mt);
    check("-3 dBFS into a -6 dB limit (dBFS)", run_tone(e, 0, 1000, pow(10, -3 / 20.0), 0.5, 4), -6, 0.01);
    mx_engine_read_meters(e, &mt);
    check("limiter gain-reduction meter (dB)", mt.limit_gr_db[4], 3, 0.1);
    check("a loud spike can't get past it (dBFS)", run_tone(e, 0, 1000, 4.0, 0.5, 4), -6, 0.01);
    check("below the limit, untouched (dBFS)", run_tone(e, 0, 1000, pow(10, -12 / 20.0), 1.0, 4), -12, 0.01);
    check("other outputs aren't limited (dBFS)", run_tone(e, 0, 1000, pow(10, -3 / 20.0), 0.5, 5), -3, 0.05);
    mx_engine_destroy(e);

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures != 0;
}

import Accelerate
import Observation

/// Spectrum of one strip, taken from the engine's capture of the signal
/// before any processing.  Updated by the meter timer only while an EQ
/// editor or the feedback screen is open.
@MainActor @Observable
final class Spectrum {
    /// dBFS of a full-scale sine landing in each FFT bin, with display
    /// ballistics.  Empty until the first update.
    private(set) var bins: [Float] = []
    private(set) var binHz = 0.0
    /// A narrow peak that has held its pitch for about a second, the way
    /// feedback does (a held note can too).  nil if there isn't one.
    private(set) var steadyHz: Double?

    @ObservationIgnored private let n = Int(MX_SCOPE_FRAMES)
    @ObservationIgnored private let log2n = vDSP_Length(log2(Double(MX_SCOPE_FRAMES)))
    @ObservationIgnored private let fft: FFTSetup
    @ObservationIgnored private let window: [Float]
    @ObservationIgnored private var samples: [Float]
    @ObservationIgnored private var re: [Float]
    @ObservationIgnored private var im: [Float]
    @ObservationIgnored private var mags: [Float]
    @ObservationIgnored private var source: Int32 = -1
    @ObservationIgnored private var candidate = -1      // bin of the peak being followed
    @ObservationIgnored private var candidateTicks = 0  // updates it has lasted
    @ObservationIgnored private var candidateMisses = 0
    @ObservationIgnored private var cum: [Float] = []

    init() {
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        samples = Array(repeating: 0, count: n)
        re = Array(repeating: 0, count: n / 2)
        im = Array(repeating: 0, count: n / 2)
        mags = Array(repeating: 0, count: n / 2)
    }

    func update(engine: OpaquePointer, source: Int32, sampleRate: Double) {
        mx_engine_read_scope(engine, source, &samples)
        vDSP.multiply(samples, window, result: &samples)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        mags[0] = 0   // DC, with Nyquist packed into its imaginary part

        // zrip returns twice the DFT and the Hann window halves a sine's
        // peak, so a sine of amplitude A gives |X| = A * n / 2.
        let offset = 20 * log10(2 / Float(n))
        let fall: Float = 0.8   // dB per update, ~24 dB/s, like the meters
        var next = mags.map { 10 * log10(max($0, 1e-20)) + offset }
        binHz = sampleRate / Double(n)
        if source != self.source { candidate = -1; candidateTicks = 0 }
        followPeak(next)   // on the raw levels: the ballistics would hold a peak after it stops
        if source == self.source && bins.count == next.count {
            for i in next.indices { next[i] = max(next[i], bins[i] - fall) }
        }
        self.source = source
        bins = next
    }

    /// Updates steadyHz.  The meter timer runs at 30 Hz, so 30 updates on
    /// the same bin (give or take one, with a few dropouts) is a second.
    private func followPeak(_ lv: [Float]) {
        let peak = prominentPeak(lv)
        if let p = peak, candidate >= 0, abs(p.bin - candidate) <= 1 {
            candidate = p.bin
            candidateTicks += 1
            candidateMisses = 0
        } else if peak == nil, candidate >= 0, candidateMisses < 3 {
            candidateMisses += 1
        } else {
            candidate = peak?.bin ?? -1
            candidateTicks = 0
            candidateMisses = 0
        }
        let hz = candidateTicks >= 30 ? (peak?.hz ?? steadyHz) : nil
        if hz != steadyHz { steadyHz = hz }
    }

    /// The bin from 100 Hz to 12 kHz that stands furthest above the third of
    /// an octave either side of it, if that's at least 15 dB and the peak is
    /// above −60 dBFS.  Its frequency is refined between bins.
    private func prominentPeak(_ lv: [Float]) -> (bin: Int, hz: Double)? {
        let count = lv.count
        if cum.count != count + 1 { cum = Array(repeating: 0, count: count + 1) }
        for i in 0..<count { cum[i + 1] = cum[i] + lv[i] }
        let lo = max(3, Int(100 / binHz)), hi = min(count - 4, Int(12000 / binHz))
        guard lo < hi else { return nil }
        var best = -1
        var bestProminence: Float = 15
        for i in lo...hi where lv[i] > -60 && lv[i] >= lv[i - 1] && lv[i] > lv[i + 1] {
            // Skip the peak's own skirt (the Hann window spreads a sine over ±2 bins).
            let w = max(6, Int(Double(i) * 0.12))
            let a = max(1, i - w), b = min(count - 1, i + w)
            let sum = cum[b + 1] - cum[a] - (cum[i + 3] - cum[i - 2])
            let prominence = lv[i] - sum / Float(b - a + 1 - 5)
            if prominence > bestProminence { bestProminence = prominence; best = i }
        }
        guard best >= 0 else { return nil }
        let l = lv[best - 1], c = lv[best], r = lv[best + 1]
        let d = l - 2 * c + r
        let shift = d < 0 ? Double(0.5 * (l - r) / d) : 0
        return (best, (Double(best) + shift) * binHz)
    }

    /// Level at a frequency: the loudest bin between f0 and f1, or an
    /// interpolated value where bins are wider than that.
    func level(from f0: Double, to f1: Double) -> Float? {
        guard !bins.isEmpty, binHz > 0 else { return nil }
        let a = f0 / binHz, b = f1 / binHz
        guard a >= 1, a < Double(bins.count - 1) else { return nil }
        let i0 = Int(a), i1 = min(bins.count - 1, Int(b))
        if i1 <= i0 + 1 {
            let t = Float(a - Double(i0))
            return bins[i0] * (1 - t) + bins[i0 + 1] * t
        }
        return bins[(i0 + 1)...i1].max()
    }
}

import Accelerate
import Observation

/// Spectrum of whatever the EQ editor is showing, taken from the engine's
/// capture of the signal before any processing.  Updated by the meter timer
/// only while an EQ editor is open.
@MainActor @Observable
final class Spectrum {
    /// dBFS of a full-scale sine landing in each FFT bin, with display
    /// ballistics.  Empty until the first update.
    private(set) var bins: [Float] = []
    private(set) var binHz = 0.0

    @ObservationIgnored private let n = Int(MX_SCOPE_FRAMES)
    @ObservationIgnored private let log2n = vDSP_Length(log2(Double(MX_SCOPE_FRAMES)))
    @ObservationIgnored private let fft: FFTSetup
    @ObservationIgnored private let window: [Float]
    @ObservationIgnored private var samples: [Float]
    @ObservationIgnored private var re: [Float]
    @ObservationIgnored private var im: [Float]
    @ObservationIgnored private var mags: [Float]
    @ObservationIgnored private var source: Int32 = -1

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
        if source == self.source && bins.count == next.count {
            for i in next.indices { next[i] = max(next[i], bins[i] - fall) }
        }
        self.source = source
        binHz = sampleRate / Double(n)
        bins = next
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

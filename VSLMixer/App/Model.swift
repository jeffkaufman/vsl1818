import Foundation

let channelCount = Int(MX_CHANNELS)
let mixCount = Int(MX_MIXES)

/// Fader positions run 0...1.  The bottom of the travel is off; everything
/// above it covers −30…+10 dB, so the fader's length goes to useful levels.
enum FaderScale {
    static let unity = 0.75
    static let off = 0.03   // below this the fader is fully off

    // Breakpoints (position, dB); linear in dB between them.
    private static let points: [(p: Double, db: Double)] = [
        (off, -30), (0.25, -20), (0.5, -10), (0.75, 0), (1.0, 10)]

    /// Bumped whenever the mapping changes, so saved positions can be converted.
    static let currentTaper = 2

    static func db(_ position: Double) -> Double {
        if position < off { return -.infinity }
        for i in 1..<points.count where position <= points[i].p {
            let a = points[i - 1], b = points[i]
            return a.db + (position - a.p) / (b.p - a.p) * (b.db - a.db)
        }
        return points.last!.db
    }

    static func position(forDb d: Double) -> Double {
        if d < points[0].db { return 0 }
        for i in 1..<points.count where d <= points[i].db {
            let a = points[i - 1], b = points[i]
            return a.p + (d - a.db) / (b.db - a.db) * (b.p - a.p)
        }
        return 1
    }

    static func gain(_ position: Double) -> Float {
        let d = db(position)
        return d.isInfinite ? 0 : Float(pow(10, d / 20))
    }

    static func label(_ position: Double) -> String {
        let d = db(position)
        if d.isInfinite { return "−∞ dB" }
        return signedDb(d)
    }

    /// Rewrites positions saved under an older mapping so levels don't change.
    static func migrate(_ mixes: inout [Mix], from taper: Int?) {
        guard taper != currentTaper else { return }
        func convert(_ p: Double) -> Double {   // taper 1: 0.8 was unity
            let v = p * 100
            if v <= 0 { return 0 }
            return position(forDb: v >= 40 ? (v - 80) * 0.5 : -20 - (40 - v) * 1.5)
        }
        for m in mixes.indices {
            mixes[m].sends = mixes[m].sends.map(convert)
            mixes[m].master = convert(mixes[m].master)
        }
    }
}

func signedDb(_ d: Double, digits: Int = 1) -> String {
    let sign = d > 0.05 ? "+" : d < -0.05 ? "−" : ""
    return sign + String(format: "%.\(digits)f dB", abs(d))
}

func hzLabel(_ f: Double) -> String {
    f >= 1000 ? String(format: f >= 10000 ? "%.0f kHz" : "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
}

struct ChannelSettings: Codable, Equatable {
    static let hpfOff = 20.0   // the high-pass at its lowest setting is off

    var name: String
    var muted = false

    var hpfHz = hpfOff
    var lowDb = 0.0, lowHz = 120.0
    var midDb = 0.0, midHz = 1000.0, midQ = 1.0
    var highDb = 0.0, highHz = 8000.0

    // A 1:1 ratio with no makeup gain leaves the signal untouched.
    var thresholdDb = -18.0, ratio = 1.0, makeupDb = 0.0
    var attackMs = 10.0, releaseMs = 150.0

    init(name: String) { self.name = name }

    var hpfActive: Bool { hpfHz > Self.hpfOff + 0.5 }
    var eqActive: Bool { hpfActive || lowDb != 0 || midDb != 0 || highDb != 0 }
    var compActive: Bool { ratio > 1.001 || abs(makeupDb) > 0.001 }

    mutating func flattenEQ() {
        let fresh = ChannelSettings(name: name)
        hpfHz = fresh.hpfHz
        lowDb = fresh.lowDb; lowHz = fresh.lowHz
        midDb = fresh.midDb; midHz = fresh.midHz; midQ = fresh.midQ
        highDb = fresh.highDb; highHz = fresh.highHz
    }

    mutating func linearComp() {
        let fresh = ChannelSettings(name: name)
        thresholdDb = fresh.thresholdDb; ratio = fresh.ratio; makeupDb = fresh.makeupDb
        attackMs = fresh.attackMs; releaseMs = fresh.releaseMs
    }

    var engineSettings: mx_channel_settings {
        var c = mx_channel_settings()
        // Flat sections are skipped entirely so they're bit-exact passthrough.
        c.hpf_on = hpfActive; c.hpf_hz = Float(hpfHz)
        c.eq_on = lowDb != 0 || midDb != 0 || highDb != 0
        c.low_db = Float(lowDb); c.low_hz = Float(lowHz)
        c.mid_db = Float(midDb); c.mid_hz = Float(midHz); c.mid_q = Float(midQ)
        c.high_db = Float(highDb); c.high_hz = Float(highHz)
        c.comp_on = compActive
        c.comp_threshold_db = Float(thresholdDb); c.comp_ratio = Float(ratio)
        c.comp_makeup_db = Float(makeupDb)
        c.comp_attack_ms = Float(attackMs); c.comp_release_ms = Float(releaseMs)
        return c
    }

    /// High-pass + EQ response in dB, from the same filter design the engine runs.
    func eqResponse(at freq: Double) -> Double {
        var c = engineSettings
        return mx_eq_response_db(&c, 48000, freq)
    }

    /// Static compressor curve: output level for a given input level.
    func compOutput(forInput db: Double) -> Double {
        let over = db - thresholdDb
        return (over > 0 ? thresholdDb + over / ratio : db) + makeupDb
    }

    // Saved sessions and scenes stay loadable as fields come and go.
    private enum CodingKeys: String, CodingKey {
        case name, muted, hpfHz, lowDb, lowHz, midDb, midHz, midQ, highDb, highHz
        case thresholdDb, ratio, makeupDb, attackMs, releaseMs
        case hpfOn, eqOn, compOn   // from versions that had on/off switches
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Input")
        func d(_ k: CodingKeys, _ v: inout Double) { if let x = try? c.decodeIfPresent(Double.self, forKey: k) { v = x } }
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        d(.hpfHz, &hpfHz); d(.lowDb, &lowDb); d(.lowHz, &lowHz); d(.midDb, &midDb); d(.midHz, &midHz)
        d(.midQ, &midQ); d(.highDb, &highDb); d(.highHz, &highHz)
        d(.thresholdDb, &thresholdDb); d(.ratio, &ratio); d(.makeupDb, &makeupDb)
        d(.attackMs, &attackMs); d(.releaseMs, &releaseMs)
        if (try? c.decodeIfPresent(Bool.self, forKey: .hpfOn)) == false { hpfHz = Self.hpfOff }
        if (try? c.decodeIfPresent(Bool.self, forKey: .eqOn)) == false { lowDb = 0; midDb = 0; highDb = 0 }
        if (try? c.decodeIfPresent(Bool.self, forKey: .compOn)) == false { ratio = 1; makeupDb = 0 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(muted, forKey: .muted)
        try c.encode(hpfHz, forKey: .hpfHz)
        try c.encode(lowDb, forKey: .lowDb); try c.encode(lowHz, forKey: .lowHz)
        try c.encode(midDb, forKey: .midDb); try c.encode(midHz, forKey: .midHz); try c.encode(midQ, forKey: .midQ)
        try c.encode(highDb, forKey: .highDb); try c.encode(highHz, forKey: .highHz)
        try c.encode(thresholdDb, forKey: .thresholdDb); try c.encode(ratio, forKey: .ratio)
        try c.encode(makeupDb, forKey: .makeupDb)
        try c.encode(attackMs, forKey: .attackMs); try c.encode(releaseMs, forKey: .releaseMs)
    }
}

struct Mix: Codable, Equatable {
    var name: String
    var sends: [Double]   // fader positions, one per channel
    var master: Double
}

struct Session: Codable, Equatable {
    var channels: [ChannelSettings]
    var mixes: [Mix]
    var deviceUID: String = ""     // empty: pick the AudioBox automatically
    var sampleRate = 48000.0
    var bufferFrames = 32
    var faderTaper: Int? = FaderScale.currentTaper   // missing in older saves

    static var initial: Session {
        // Everything starts pulled down so a fresh install never surprises
        // anyone with sound (or feedback) through the PA.
        Session(
            channels: (1...channelCount).map { ChannelSettings(name: "Input \($0)") },
            mixes: (0..<mixCount).map { m in
                Mix(name: m == 0 ? "Main" : "Aux \(m)",
                    sends: Array(repeating: 0, count: channelCount),
                    master: FaderScale.unity)
            })
    }

    /// Which output jacks a mix drives.
    static func outputs(ofMix m: Int) -> String {
        m == 0 ? "Out 1–2" : "Out \(m + 2)"
    }
}

/// The part of a session that belongs to a show rather than to this
/// computer: levels, processing and names, but not the audio device.
struct MixerScene: Codable {
    var channels: [ChannelSettings]
    var mixes: [Mix]
    var faderTaper: Int? = FaderScale.currentTaper
}

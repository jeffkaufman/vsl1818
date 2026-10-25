import Foundation

let channelCount = Int(MX_CHANNELS)
let mixCount = Int(MX_MIXES)

/// Fader positions run 0...1.  The bottom of the travel is off; everything
/// above it covers −20…+10 dB, so the fader's length goes to useful levels.
enum FaderScale {
    static let unity = 0.75
    static let off = 0.001   // below this the fader is fully off; any movement leaves it

    // Breakpoints (position, dB); linear in dB between them.  The phone page
    // gets these too, so both ends agree on what a position means.
    static let points: [(p: Double, db: Double)] = [
        (off, -20), (0.5, -10), (0.75, 0), (1.0, 10)]

    /// Bumped whenever the mapping changes, so saved positions can be converted.
    static let currentTaper = 4

    static func db(_ position: Double) -> Double {
        db(position, points: points)
    }

    private static func db(_ position: Double, points: [(p: Double, db: Double)]) -> Double {
        if position < points[0].p { return -.infinity }
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
        func oldDb(_ p: Double) -> Double {
            if taper == 3 {   // off below 3%
                return db(p, points: [(0.03, -20), (0.5, -10), (0.75, 0), (1.0, 10)])
            }
            if taper == 2 {   // −30 dB at the bottom
                return db(p, points: [(0.03, -30), (0.25, -20), (0.5, -10), (0.75, 0), (1.0, 10)])
            }
            let v = p * 100   // taper 1: 0.8 was unity
            if v <= 0 { return -.infinity }
            return v >= 40 ? (v - 80) * 0.5 : -20 - (40 - v) * 1.5
        }
        func convert(_ p: Double) -> Double {   // below the new bottom is off
            position(forDb: oldDb(p))
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

    /// Allowed range for each processing parameter, by name.  Used to
    /// validate changes arriving from phones.
    static let limits: [String: (WritableKeyPath<ChannelSettings, Double>, ClosedRange<Double>)] = [
        "hpfHz": (\.hpfHz, hpfOff...400),
        "lowDb": (\.lowDb, -18...18), "lowHz": (\.lowHz, 30...500),
        "midDb": (\.midDb, -18...18), "midHz": (\.midHz, 150...8000), "midQ": (\.midQ, 0.3...5),
        "highDb": (\.highDb, -18...18), "highHz": (\.highHz, 1500...18000),
        "thresholdDb": (\.thresholdDb, -50...(-2)), "ratio": (\.ratio, 1...20), "makeupDb": (\.makeupDb, 0...20),
        "attackMs": (\.attackMs, 0.2...100), "releaseMs": (\.releaseMs, 20...1000),
    ]

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
    // The output's own EQ, compressor and mute, applied before the master.
    // Its name is unused.
    var processing = ChannelSettings(name: "")
    var delayMs = 0.0   // to line up with speakers further away

    static let maxDelayMs = Double(MX_MAX_DELAY_MS)
    static let feetPerMs = 1.125   // speed of sound at about 20 °C

    /// Auxes are named for their output jack ("Aux 3" drives out 3).  Saves
    /// from before that (auxNames nil) numbered them 1–6, so default names
    /// are renumbered; names someone typed are left alone.
    static let currentAuxNames = 2
    static func migrateNames(_ mixes: inout [Mix], from version: Int?) {
        guard version == nil else { return }
        for m in mixes.indices where m > 0 && mixes[m].name == "Aux \(m)" {
            mixes[m].name = "Aux \(m + 2)"
        }
    }

    private enum CodingKeys: String, CodingKey { case name, sends, master, processing, delayMs }
}

extension Mix {
    // Kept in an extension so the memberwise initializer survives.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        sends = try c.decode([Double].self, forKey: .sends)
        master = try c.decode(Double.self, forKey: .master)
        processing = (try? c.decodeIfPresent(ChannelSettings.self, forKey: .processing)) ?? ChannelSettings(name: "")
        delayMs = (try? c.decodeIfPresent(Double.self, forKey: .delayMs)) ?? 0
    }
}

/// Something with its own EQ, compressor and mute: an input, or an output.
enum Strip: Hashable {
    case input(Int)
    case output(Int)

    /// The next input or output, wrapping around, for Tab between names.
    func neighbor(backward: Bool) -> Strip {
        switch self {
        case .input(let c): .input((c + (backward ? channelCount - 1 : 1)) % channelCount)
        case .output(let m): .output((m + (backward ? mixCount - 1 : 1)) % mixCount)
        }
    }

    /// Index for mx_engine_read_scope.
    var scopeSource: Int32 {
        switch self {
        case .input(let c): Int32(c)
        case .output(let m): Int32(channelCount + m)
        }
    }
}

struct Session: Codable, Equatable {
    var channels: [ChannelSettings]
    var mixes: [Mix]
    var deviceUID: String = ""     // empty: pick the AudioBox automatically
    var sampleRate = 48000.0
    var bufferFrames = 32
    var faderTaper: Int? = FaderScale.currentTaper   // missing in older saves
    var auxNames: Int? = Mix.currentAuxNames          // missing in older saves

    // Phone control.  Optional so sessions saved before it existed still load.
    // Off until someone turns it on (nil counts as off), so macOS only asks
    // for Local Network access when phones are actually wanted.
    var remoteEnabled: Bool?
    var remoteCode: String?        // passcode for the whole-board page
    var wifiName: String?          // only used to draw a join-Wi-Fi QR code
    var wifiPassword: String?

    /// Inputs 1 and 2 are Jammer's main left and right rather than the jacks
    /// (Engine/jammer_link.h).  nil counts as off.
    var jammerLink: Bool?

    static var initial: Session {
        // Everything starts pulled down so a fresh install never surprises
        // anyone with sound (or feedback) through the PA.
        Session(
            channels: (1...channelCount).map { ChannelSettings(name: "Input \($0)") },
            mixes: (0..<mixCount).map { m in
                Mix(name: m == 0 ? "Main" : "Aux \(m + 2)",
                    sends: Array(repeating: 0, count: channelCount),
                    master: FaderScale.unity)
            })
    }

    subscript(strip s: Strip) -> ChannelSettings {
        get {
            switch s {
            case .input(let c): channels[c]
            case .output(let m): mixes[m].processing
            }
        }
        set {
            switch s {
            case .input(let c): channels[c] = newValue
            case .output(let m): mixes[m].processing = newValue
            }
        }
    }

    subscript(name s: Strip) -> String {
        get {
            switch s {
            case .input(let c): channels[c].name
            case .output(let m): mixes[m].name
            }
        }
        set {
            switch s {
            case .input(let c): channels[c].name = newValue
            case .output(let m): mixes[m].name = newValue
            }
        }
    }

    /// "In 3", "Out 1–2"; empty for an aux whose name already says it.
    static func jacks(of s: Strip, name: String) -> String {
        switch s {
        case .input(let c): "In \(c + 1)"
        case .output(let m): jacks(ofMix: m, name: name)
        }
    }

    /// The jack label to show under or over a mix's name: "Aux 5" doesn't
    /// need "Out 5", but "Fiddle" does.
    static func jacks(ofMix m: Int, name: String) -> String {
        m > 0 && name == "Aux \(m + 2)" ? "" : outputs(ofMix: m)
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
    var auxNames: Int? = Mix.currentAuxNames
}

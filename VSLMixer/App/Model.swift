import Foundation

let channelCount = Int(MX_CHANNELS)
let mixCount = Int(MX_MIXES)
let pairCount = Int(MX_PAIRS)

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
        Float(linear(position))
    }

    static func linear(_ position: Double) -> Double {
        let d = db(position)
        return d.isInfinite ? 0 : pow(10, d / 20)
    }

    /// Below the bottom of the scale is off; above the top, the top.
    static func position(forGain g: Double) -> Double {
        g > 0 ? position(forDb: 20 * log10(g)) : 0
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

/// "C", "L 40", "R 100".
func panLabel(_ p: Double) -> String {
    let n = Int((abs(p) * 100).rounded())
    return n == 0 ? "C" : (p < 0 ? "L \(n)" : "R \(n)")
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
    /// Where each input sits, −1 left … +1 right.  Only used while the mix
    /// is stereo (its pair is linked).
    var pans = Array(repeating: 0.0, count: channelCount)
    /// Nothing leaves the output above this, in dBFS.
    var limitDb = Mix.defaultLimitDb

    static let maxDelayMs = Double(MX_MAX_DELAY_MS)
    static let feetPerMs = 1.125   // speed of sound at about 20 °C

    /// 6 dB under full scale, so a feedback squeal or a dropped mic can't
    /// reach full volume in someone's ears.  Set the in-ear pack's volume
    /// with this in place.
    static let defaultLimitDb = -6.0
    static let limitRange = -30.0...0.0

    /// Within this of center, a pan snaps to it.
    static let panDetent = 0.03

    /// Left and right gains for a pan, the same law as the engine's
    /// pan_gains: center is unity on both sides, hard left or right +3 dB.
    static func panGains(_ p: Double) -> (l: Double, r: Double) {
        if p == 0 { return (1, 1) }
        if abs(p) >= 1 { return p < 0 ? (2.squareRoot(), 0) : (0, 2.squareRoot()) }
        let a = (min(1, max(-1, p)) + 1) * .pi / 4
        return (2.squareRoot() * cos(a), 2.squareRoot() * sin(a))
    }

    /// Makes this (the left mix of a pair) the stereo mix that plays what it
    /// and `right` played on their two outs: each input's two sends become
    /// one send and a pan.  Right's master is folded into the sends; its
    /// EQ, compressor, delay and limit have no equivalent and are dropped.
    mutating func absorb(_ right: Mix) {
        let m0 = FaderScale.linear(master), m1 = FaderScale.linear(right.master)
        let rightOn = right.processing.muted ? 0.0 : 1.0
        for c in sends.indices {
            // Gains relative to this mix's master, which the stereo mix keeps.
            let a = FaderScale.linear(sends[c])
            let b = FaderScale.linear(right.sends[c]) * rightOn * (m0 > 0 ? m1 / m0 : 1)
            let pan = 4 / Double.pi * atan2(b, a) - 1
            sends[c] = FaderScale.position(forGain: ((a * a + b * b) / 2).squareRoot())
            pans[c] = a == 0 && b == 0 || abs(pan) < 1e-9 ? 0 : pan
        }
    }

    /// The reverse of `absorb`: splits this stereo mix into itself, now the
    /// left side, and returns the right side as a mix of its own, with the
    /// same master and processing, named `name`.
    mutating func splitOff(named name: String) -> Mix {
        var right = self
        right.name = name
        for c in sends.indices {
            let g = FaderScale.linear(sends[c]), (l, r) = Mix.panGains(pans[c])
            sends[c] = FaderScale.position(forGain: g * l)
            right.sends[c] = FaderScale.position(forGain: g * r)
            right.pans[c] = 0
        }
        return right
    }

    /// Brings mixes saved by older versions up to date.  Before version 2,
    /// auxes were numbered 1–6 rather than for their output jack, so default
    /// names are renumbered (names someone typed are left alone).  Before
    /// version 3 there were seven mixes, without Aux 2, so it's added.
    static let currentAuxNames = 3
    static func migrateNames(_ mixes: inout [Mix], from version: Int?) {
        if version == nil {
            for m in mixes.indices where m > 0 && mixes[m].name == "Aux \(m)" {
                mixes[m].name = "Aux \(m + 2)"
            }
        }
        if mixes.count == mixCount - 1 {
            mixes.insert(Mix(name: "Aux 2", sends: Array(repeating: 0, count: channelCount),
                             master: FaderScale.unity), at: 1)
        }
    }

    private enum CodingKeys: String, CodingKey { case name, sends, master, processing, delayMs, pans, limitDb }
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
        let p = (try? c.decodeIfPresent([Double].self, forKey: .pans)) ?? nil
        pans = p?.count == sends.count ? p! : Array(repeating: 0, count: sends.count)
        limitDb = (try? c.decodeIfPresent(Double.self, forKey: .limitDb)) ?? Mix.defaultLimitDb
    }
}

/// Something with its own EQ, compressor and mute: an input, or an output.
enum Strip: Hashable {
    case input(Int)
    case output(Int)

    /// The next input or output, wrapping around, for Tab between names.
    func neighbor(backward: Bool, in session: Session) -> Strip {
        switch self {
        case .input(let c): return .input((c + (backward ? channelCount - 1 : 1)) % channelCount)
        case .output(let m):
            let shown = session.shownMixes, i = shown.firstIndex(of: m) ?? 0
            return .output(shown[(i + (backward ? shown.count - 1 : 1)) % shown.count])
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

    /// Which pairs of outs (1+2, 3+4, 5+6, 7+8) play one stereo mix rather
    /// than two mono ones.  nil: only 1+2, as Main.
    var linkedPairs: [Bool]?
    /// From before stereo pairs: true meant outs 1 and 2 were Aux 1 and Aux 2.
    /// Only read, by `migrateLinks`.
    var splitMain: Bool?

    /// Outs 1+2 are Main and 7+8 a stereo in-ear mix; 3–6 are mono auxes.
    static let initialLinks = [true, false, false, true]

    static var initial: Session {
        // Everything starts pulled down so a fresh install never surprises
        // anyone with sound (or feedback) through the PA.
        Session(
            channels: (1...channelCount).map { ChannelSettings(name: "Input \($0)") },
            mixes: (0..<mixCount).map { m in
                Mix(name: defaultName(ofMix: m, linked: m % 2 == 0 && initialLinks[m / 2]),
                    sends: Array(repeating: 0, count: channelCount),
                    master: FaderScale.unity)
            },
            linkedPairs: initialLinks)
    }

    mutating func migrateLinks() {
        if linkedPairs?.count != pairCount {
            linkedPairs = [splitMain != true] + Array(repeating: false, count: pairCount - 1)
        }
        splitMain = nil
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

    func isLinked(pair p: Int) -> Bool {
        if let l = linkedPairs, l.indices.contains(p) { return l[p] }
        return p == 0
    }

    private mutating func setLinked(pair p: Int, _ on: Bool) {
        var l = (0..<pairCount).map { isLinked(pair: $0) }
        l[p] = on
        linkedPairs = l
    }

    /// Links or unlinks a pair without changing what either out plays, as
    /// far as sends, pans and masters can say it (see `Mix.absorb`).  A
    /// default name follows: "Aux 3" ↔ "Aux 3+4", "Aux 1" ↔ "Main".
    mutating func link(pair p: Int, _ on: Bool) {
        guard on != isLinked(pair: p) else { return }
        let l = 2 * p, r = l + 1
        if on {
            mixes[l].absorb(mixes[r])
        } else {
            mixes[r] = mixes[l].splitOff(named: mixes[r].name)
        }
        if mixes[l].name == Self.defaultName(ofMix: l, linked: !on) {
            mixes[l].name = Self.defaultName(ofMix: l, linked: on)
        }
        setLinked(pair: p, on)
    }

    /// Mix m drives out m + 1, except that in a linked pair the even mix
    /// drives both outs in stereo and the odd one is unused.
    func isStereo(_ m: Int) -> Bool { m % 2 == 0 && isLinked(pair: m / 2) }

    /// The mixes in use, in order.
    var shownMixes: [Int] { (0..<mixCount).filter { $0 % 2 == 0 || !isLinked(pair: $0 / 2) } }

    /// A mix a musician can take over from a phone: anything shown but Main.
    func isAux(_ m: Int) -> Bool { shownMixes.contains(m) && (m > 0 || !isLinked(pair: 0)) }

    /// Outs 1+2 linked are Main; other linked pairs are "Aux 3+4" and so on.
    static func defaultName(ofMix m: Int, linked: Bool) -> String {
        !linked ? "Aux \(m + 1)" : m == 0 ? "Main" : "Aux \(m + 1)+\(m + 2)"
    }

    /// "In 3", "Out 1+2"; empty for an aux whose name already says it.
    func jacks(of s: Strip) -> String {
        switch s {
        case .input(let c): "In \(c + 1)"
        case .output(let m): jacks(ofMix: m)
        }
    }

    /// The jack label to show under or over a mix's name: "Aux 5" doesn't
    /// need "Out 5", but "Fiddle" does.
    func jacks(ofMix m: Int) -> String {
        isAux(m) && mixes[m].name == Self.defaultName(ofMix: m, linked: isStereo(m)) ? "" : outputs(ofMix: m)
    }

    /// Which output jacks a mix drives.
    func outputs(ofMix m: Int) -> String {
        isStereo(m) ? "Out \(m + 1)+\(m + 2)" : "Out \(m + 1)"
    }
}

/// The part of a session that belongs to a show rather than to this
/// computer: levels, processing and names, but not the audio device.
struct MixerScene: Codable {
    var channels: [ChannelSettings]
    var mixes: [Mix]
    /// Which pairs of outs are stereo.  nil in scenes from before they were
    /// saved, which leave the linking as it is.
    var linkedPairs: [Bool]?
    var faderTaper: Int? = FaderScale.currentTaper
    var auxNames: Int? = Mix.currentAuxNames
}

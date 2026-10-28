import CoreMIDI
import Foundation

/// Records what's played on every MIDI device during a recording, to a
/// Standard MIDI File with a track per device.  Jammer reads the same
/// devices (its pedals, breath controller and piano), and any number of
/// apps can, so with Jammer linked this is what was played into it.
///
/// Jammer's own "Jammer Keys" source is one of them: what's struck on the
/// laptop or said to it.  A recording that starts partway through a set
/// would miss what Jammer had been told before, so starting one says so on
/// VSL Mixer's own source (CC 119 on channel 16), and Jammer answers with
/// everything so far, between markers (see jammer-mac.m's "Logging what's
/// played on the laptop").
///
/// Times come from the audio: each event is placed by where the recording
/// had got to when it arrived (mx_engine_record_origin), so it lines up
/// with the WAVs and doesn't drift over a long set.  Channel messages only;
/// clock, other system messages and SysEx are left out.
final class MidiRecorder: @unchecked Sendable {
    private struct Event {
        let source: Int
        let frame: Double   // in the recording, at its sample rate
        let bytes: [UInt8]
    }

    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var ownSource = MIDIEndpointRef()   // "VSL Mixer", for asking Jammer
    private var sources: [MIDIEndpointRef] = []   // index is the track
    private var names: [String] = []
    // Only while recording:
    private var running = false
    private var events: [Event] = []
    private var engine: OpaquePointer?
    private var ticksPerFrame = 0.0

    private static let ticksPerQuarter = 960
    private static let ticksPerSecond = 2.0 * Double(ticksPerQuarter)   // at 120 bpm

    /// Nil if CoreMIDI isn't available.
    init?() {
        let made = MIDIClientCreateWithBlock("VSL Mixer" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { self?.connectSources() }
        }
        guard made == noErr else { return nil }
        let opened = MIDIInputPortCreateWithProtocol(client, "VSL Mixer input" as CFString, ._1_0, &port) {
            [weak self] list, refCon in
            self?.receive(list, from: Int(bitPattern: refCon) - 1)
        }
        guard opened == noErr else { return nil }
        // Made well before any recording, so Jammer has found it by then.
        MIDISourceCreateWithProtocol(client, "VSL Mixer" as CFString, ._1_0, &ownSource)
        connectSources()
    }

    /// Starts collecting; `engine` must be recording already.
    func start(engine: OpaquePointer, sampleRate: Double) {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        lock.lock()
        self.engine = engine
        ticksPerFrame = 1e9 * Double(tb.denom) / Double(tb.numer) / sampleRate
        events = []
        running = true
        lock.unlock()
        connectSources()
        askForHistory()
    }

    /// Tells Jammer a recording has started, so it sends what came before.
    private func askForHistory() {
        guard ownSource != 0 else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2) << 28 | UInt32(0xBF) << 16 | UInt32(119) << 8 | 127
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, mach_absolute_time(), 1, &word)
        MIDIReceivedEventList(ownSource, &list)
    }

    /// Stops, and writes `url` if anything was played.  Returns whether it did.
    @discardableResult
    func stop(writingTo url: URL, sampleRate: Double) -> Bool {
        lock.lock()
        running = false
        let got = events, trackNames = names
        events = []
        engine = nil
        lock.unlock()
        guard !got.isEmpty else { return false }
        let data = Self.smf(got, names: trackNames, sampleRate: sampleRate)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Connects every source, including ones plugged in (or back in) mid-set.
    /// A device keeps its track if it comes back.
    private func connectSources() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0, src != ownSource else { continue }
            let track: Int
            if let known = sources.firstIndex(of: src) {
                track = known
                MIDIPortDisconnectSource(port, src)
            } else {
                track = sources.count
                sources.append(src)
                names.append(Self.name(of: src))
            }
            MIDIPortConnectSource(port, src, UnsafeMutableRawPointer(bitPattern: track + 1))
        }
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &s) == noErr, let s {
            return s.takeRetainedValue() as String
        }
        return "MIDI"
    }

    // CoreMIDI's thread.
    private func receive(_ list: UnsafePointer<MIDIEventList>, from source: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard running, let engine, source >= 0 else { return }
        let origin = mx_engine_record_origin(engine)
        for packet in list.unsafeSequence() {
            let host = packet.pointee.timeStamp != 0 ? packet.pointee.timeStamp : mach_absolute_time()
            let frame = origin > 0 ? max(0, (Double(host) - origin) / ticksPerFrame) : 0
            let words = withUnsafeBytes(of: packet.pointee.words) {
                Array($0.bindMemory(to: UInt32.self).prefix(Int(packet.pointee.wordCount)))
            }
            for bytes in Self.channelMessages(in: words) {
                events.append(Event(source: source, frame: frame, bytes: bytes))
            }
        }
    }

    /// MIDI 1.0 channel voice messages (UMP type 2) as plain MIDI bytes.
    private static func channelMessages(in words: [UInt32]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < words.count {
            let w = words[i], type = w >> 28
            if type == 2 {
                let status = UInt8((w >> 16) & 0xFF)
                let d1 = UInt8((w >> 8) & 0x7F), d2 = UInt8(w & 0x7F)
                out.append(status & 0xE0 == 0xC0 ? [status, d1] : [status, d1, d2])   // program, aftertouch
            }
            // Message lengths in words, by type (UMP spec).
            i += [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(type)]
        }
        return out
    }

    /// Format 1: a tempo track, then one per device that was played.
    private static func smf(_ events: [Event], names: [String], sampleRate: Double) -> Data {
        func vlq(_ v: Int) -> [UInt8] {
            var v = v, bytes = [UInt8(v & 0x7F)]
            while v > 0x7F { v >>= 7; bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0) }
            return bytes
        }
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { Array(type.utf8) + be(body.count, 4) + body }
        let end: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

        var tracks = [chunk("MTrk", [0x00, 0xFF, 0x51, 0x03] + be(500_000, 3) + end)]   // 120 bpm
        for source in Set(events.map(\.source)).sorted() {
            let name = Array((source < names.count ? names[source] : "MIDI").utf8)
            var body: [UInt8] = [0x00, 0xFF, 0x03] + vlq(name.count) + name
            var last = 0
            // By time, not arrival: a sender may stamp a message ahead (Jammer
            // stamps a key's note off 50 ms on).  Ties keep arrival order.
            let mine = events.enumerated().filter { $0.element.source == source }
                .sorted { ($0.element.frame, $0.offset) < ($1.element.frame, $1.offset) }.map(\.element)
            for e in mine {
                let tick = max(last, Int((e.frame / sampleRate * ticksPerSecond).rounded()))
                body += vlq(tick - last) + e.bytes
                last = tick
            }
            tracks.append(chunk("MTrk", body + end))
        }
        let header = chunk("MThd", be(1, 2) + be(tracks.count, 2) + be(ticksPerQuarter, 2))
        return Data(header + tracks.flatMap { $0 })
    }
}

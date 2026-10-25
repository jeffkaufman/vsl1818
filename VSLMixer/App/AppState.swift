import AppKit
import AVFoundation
import IOKit.pwr_mgt
import Observation

enum Route: Equatable {
    case mixer
    case eq(Strip)
    case comp(Strip)
}

/// Meter readings in dBFS, with display ballistics applied.
@MainActor @Observable
final class Meters {
    var input = Array(repeating: -120.0, count: channelCount)
    var gainReduction = Array(repeating: 0.0, count: channelCount)
    var mixIn = Array(repeating: -120.0, count: mixCount)   // before the output's processing
    var mixGainReduction = Array(repeating: 0.0, count: mixCount)
    var mix = Array(repeating: -120.0, count: mixCount)
    // Latched until clicked, so a clip mid-tune isn't missed.
    var inputClipped = Array(repeating: false, count: channelCount)
    var mixClipped = Array(repeating: false, count: mixCount)

    /// Inputs come from a 24-bit converter, which tops out just under 1.0;
    /// outputs clip at the converter once they pass 1.0.
    static let inputClipLevel: Float = 0.99
    static let outputClipLevel: Float = 1.0

    /// What goes into a strip's EQ and compressor.
    func level(before s: Strip) -> Double {
        switch s {
        case .input(let c): input[c]
        case .output(let m): mixIn[m]
        }
    }

    func gainReduction(of s: Strip) -> Double {
        switch s {
        case .input(let c): gainReduction[c]
        case .output(let m): mixGainReduction[m]
        }
    }
}

struct AudioStatus: Equatable {
    enum State: Equatable {
        case starting
        case running
        case problem(String)
        case needsPermission
    }
    var state = State.starting
    var sampleRate = 0.0
    var bufferFrames = 0
    var latencyMs = 0.0
    var dropouts = 0
    var jammerLinked = false   // inputs 1–2 are taken from Jammer
    var jammerAlive = false    // and Jammer is playing into them
}

struct ActiveRecording {
    let folder: URL
    let started: Date
    let names: [String]
}

@MainActor @Observable
final class AppState {
    var session: Session {
        didSet { sessionChanged(from: oldValue) }
    }
    var selectedMix = 0
    var route = Route.mixer {
        didSet { editingName = nil }
    }
    var editingName: Strip?   // the mixer name being renamed in place, if any
    var showSetup = false
    var status = AudioStatus()
    var jammerLinkFailed = false
    var recording: ActiveRecording?
    var lastRecording: URL?
    var recordingError: String?
    var recordingSecondsLeft: Double?
    var showPhones = false
    var remoteStatus = RemoteServer.Status.off
    var remoteConnections: [String] = []   // e.g. "Aux 4 (Fiddle)", "Whole board"
    var now = Date()
    let meters = Meters()
    let spectrum = Spectrum()

    @ObservationIgnored private let engine: OpaquePointer = mx_engine_create()
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var watchdogTimer: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var permissionGranted = false
    @ObservationIgnored private var lastCallbacks: UInt64 = 0
    @ObservationIgnored private var stalledTicks = 0
    @ObservationIgnored private var retryTicks = 0
    @ObservationIgnored private var failedRestarts = 0
    @ObservationIgnored private var meterTicks = 0
    @ObservationIgnored private(set) var remote: RemoteServer!
    @ObservationIgnored private var sleepAssertion: IOPMAssertionID = 0
    @ObservationIgnored private var activationObservers: [NSObjectProtocol] = []

    init() {
        session = Self.loadSession() ?? .initial
        pushAll()
        refreshScenes()
        remote = RemoteServer(app: self)
        if session.remoteCode == nil { session.remoteCode = Self.newPasscode() }
        if session.remoteEnabled == true { remote.start() }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readMeters() }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
        RunLoop.main.add(watchdogTimer!, forMode: .common)
        requestMicrophone()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSleepAssertion() }
            })
        }
    }

    func shutdown() {
        allowSleep()
        remote?.stop()
        stopRecording()
        mx_engine_stop(engine)
        saveNow()
    }

    // MARK: - engine

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
            startEngine()
        case .notDetermined:
            status.state = .problem("Waiting for microphone permission")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.permissionGranted = granted
                    if granted { self.startEngine() } else { self.status.state = .needsPermission }
                }
            }
        default:
            status.state = .needsPermission
        }
    }

    private func startEngine() {
        let err = session.deviceUID.withCString {
            mx_engine_start(engine, $0, session.sampleRate, UInt32(session.bufferFrames))
        }
        var st = mx_stats()
        mx_engine_get_stats(engine, &st)
        lastCallbacks = st.callbacks   // cumulative across restarts
        stalledTicks = 0
        retryTicks = 4
        switch err {
        case 0:
            status.state = .running
            refreshStats()
        case Int32(MX_ERR_NO_DEVICE):
            status.state = .problem("Interface not connected")
        case Int32(MX_ERR_TOO_FEW_CHANNELS):
            status.state = .problem("This interface has fewer than 8 inputs and outputs")
        default:
            status.state = .problem("Couldn't start audio (error \(err))")
        }
    }

    private func restartEngine() {
        mx_engine_stop(engine)
        if permissionGranted { startEngine() }
    }

    private func refreshStats() {
        var st = mx_stats()
        mx_engine_get_stats(engine, &st)
        status.sampleRate = st.sample_rate
        status.bufferFrames = Int(st.buffer_frames)
        status.latencyMs = st.sample_rate > 0 ? 1000 * Double(st.latency_frames) / st.sample_rate : 0
        status.dropouts = Int(st.dropouts)
        status.jammerLinked = st.jammer_linked
        status.jammerAlive = st.jammer_alive
    }

    /// Every half second: notice stalls, unplugs and outside sample-rate
    /// changes, and bring the audio back without anyone touching the laptop.
    private func watchdog() {
        now = Date()
        updateRecordingTimeLeft()
        updateSleepAssertion()
        guard permissionGranted else { return }
        var st = mx_stats()
        mx_engine_get_stats(engine, &st)

        if !st.running {
            retryTicks -= 1
            if retryTicks <= 0 { startEngine() }
            return
        }

        stalledTicks = st.callbacks == lastCallbacks ? stalledTicks + 1 : 0
        if stalledTicks == 0 { failedRestarts = 0 }
        lastCallbacks = st.callbacks
        refreshStats()

        if !st.alive {
            mx_engine_stop(engine)
            status.state = .problem("Interface disconnected — waiting for it")
        } else if stalledTicks >= 3 {
            failedRestarts += 1
            restartEngine()   // an in-progress recording keeps going across the restart
            if failedRestarts >= 3 {
                status.state = .problem("Interface isn't sending audio — try switching it off and on")
            }
        } else if st.sample_rate > 0 && st.sample_rate != session.sampleRate {
            stopRecording()
            restartEngine()
        } else if stalledTicks == 0 && status.state != .running {
            status.state = .running
        }
    }

    private func readMeters() {
        var raw = mx_meters()
        mx_engine_read_meters(engine, &raw)
        let input = withUnsafeBytes(of: raw.in_peak) { Array($0.bindMemory(to: Float.self)) }
        let gr = withUnsafeBytes(of: raw.gr_db) { Array($0.bindMemory(to: Float.self)) }
        let mixIn = withUnsafeBytes(of: raw.mix_in_peak) { Array($0.bindMemory(to: Float.self)) }
        let mixGR = withUnsafeBytes(of: raw.mix_gr_db) { Array($0.bindMemory(to: Float.self)) }
        let mix = withUnsafeBytes(of: raw.mix_peak) { Array($0.bindMemory(to: Float.self)) }
        // Peaks jump up immediately and fall back at 24 dB/s.
        let fall = 24.0 / 30
        func ballistic(_ old: Double, _ peak: Float) -> Double {
            let db = peak > 0 ? 20 * log10(Double(peak)) : -120
            return max(db, old - fall)
        }
        for c in 0..<channelCount {
            meters.input[c] = ballistic(meters.input[c], input[c])
            meters.gainReduction[c] = Double(gr[c])
            if input[c] >= Meters.inputClipLevel && !meters.inputClipped[c] { meters.inputClipped[c] = true }
        }
        for m in 0..<mixCount {
            meters.mixIn[m] = ballistic(meters.mixIn[m], mixIn[m])
            meters.mixGainReduction[m] = Double(mixGR[m])
            meters.mix[m] = ballistic(meters.mix[m], mix[m])
            if mix[m] >= Meters.outputClipLevel && !meters.mixClipped[m] { meters.mixClipped[m] = true }
        }
        if case .eq(let strip) = route {
            spectrum.update(engine: engine, source: strip.scopeSource,
                            sampleRate: status.sampleRate > 0 ? status.sampleRate : session.sampleRate)
        }
        meterTicks += 1
        if meterTicks % 2 == 0 { remote?.broadcastMeters(meters) }
    }

    // MARK: - sleep

    /// Keeps the Mac awake with the display on, undimmed and unlocked while
    /// the mixer is in front and audio is running, so a quiet stretch of a
    /// dance doesn't dim, lock or sleep it.  (Locking follows the screen
    /// saver and display sleep, which this holds off.)  Closing the lid
    /// still sleeps it; macOS doesn't let apps prevent that.
    private func updateSleepAssertion() {
        if NSApp.isActive && status.state == .running {
            guard sleepAssertion == 0 else { return }
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "VSL Mixer is running live sound" as CFString, &sleepAssertion)
        } else {
            allowSleep()
        }
    }

    private func allowSleep() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        sleepAssertion = 0
    }

    // MARK: - settings

    private func sessionChanged(from old: Session) {
        if old.deviceUID != session.deviceUID || old.sampleRate != session.sampleRate
            || old.bufferFrames != session.bufferFrames {
            if old.sampleRate != session.sampleRate { stopRecording() }
            restartEngine()
        }
        if old.remoteEnabled != session.remoteEnabled {
            if session.remoteEnabled == true { remote?.start() } else { remote?.stop() }
        }
        if old.remoteCode != session.remoteCode && old.remoteCode != nil { remote?.revokeBoard() }
        pushAll()
        remote?.markDirty()
        scheduleSave()
    }

    // MARK: - phones

    static func newPasscode() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

    func remoteClientsChanged() {
        remoteConnections = (remote?.roles ?? []).map { role in
            switch role {
            case .board: return "Whole board"
            case .aux(let m): return session.mixes[m].name
            default: return ""
            }
        }.filter { !$0.isEmpty }.sorted()
    }

    private func pushAll() {
        let linkFailed = !mx_engine_set_jammer_link(engine, session.jammerLink == true)
        if linkFailed != jammerLinkFailed { jammerLinkFailed = linkFailed }
        mx_engine_set_split_main(engine, session.splitMain == true)
        for (c, ch) in session.channels.enumerated() {
            var s = ch.engineSettings
            mx_engine_set_channel(engine, Int32(c), &s)
            mx_engine_set_mute(engine, Int32(c), ch.muted)
        }
        for (m, mix) in session.mixes.enumerated() {
            var s = mix.processing.engineSettings
            mx_engine_set_mix_processing(engine, Int32(m), &s)
            mx_engine_set_mix_mute(engine, Int32(m), mix.processing.muted)
            mx_engine_set_mix_delay(engine, Int32(m), Float(mix.delayMs))
            mx_engine_set_master(engine, Int32(m), FaderScale.gain(mix.master))
            for (c, pos) in mix.sends.enumerated() {
                mx_engine_set_send(engine, Int32(m), Int32(c), FaderScale.gain(pos))
            }
        }
    }

    func availableDevices() -> [(name: String, uid: String)] {
        var list = [mx_device_info](repeating: mx_device_info(), count: 32)
        let n = Int(mx_list_devices(&list, 32))
        return list.prefix(n).map { d in
            var d = d
            let name = withUnsafePointer(to: &d.name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let uid = withUnsafePointer(to: &d.uid) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            return (name, uid)
        }
    }

    // MARK: - recording

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VSL Mixer", isDirectory: true)
    }

    func toggleRecording() {
        if recording != nil { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recordingError = nil
        guard case .running = status.state else {
            recordingError = "Audio isn't running"
            return
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = Self.recordingsFolder.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            recordingError = "Couldn't create \(folder.path)"
            return
        }
        let err = folder.path.withCString { mx_engine_record_start(engine, $0) }
        if err != 0 {
            recordingError = "Couldn't create the recording files"
            return
        }
        recording = ActiveRecording(folder: folder, started: Date(),
                                    names: session.channels.map(\.name))
    }

    /// Whichever runs out first: free disk space, or the 4 GB limit on each
    /// track's WAV file (about 8 hours at 48 kHz).
    private func updateRecordingTimeLeft() {
        guard let rec = recording, status.sampleRate > 0 else { recordingSecondsLeft = nil; return }
        let trackBytesPerSecond = 3 * status.sampleRate
        let wavLeft = (4_294_967_295.0 - 44) / trackBytesPerSecond - now.timeIntervalSince(rec.started)
        var left = wavLeft
        if let free = try? rec.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            left = min(left, Double(free) / (trackBytesPerSecond * Double(channelCount)))
        }
        recordingSecondsLeft = max(0, left)
        if left <= 1 {
            stopRecording()   // closes the files cleanly instead of failing mid-write
            recordingError = "Recording stopped: disk full or 4 GB file limit reached"
        }
    }

    private func stopRecording() {
        guard let rec = recording else { return }
        mx_engine_record_stop(engine)
        recording = nil
        // The engine writes in1.wav ... in8.wav; give them the channel names.
        for (c, name) in rec.names.enumerated() {
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let from = rec.folder.appendingPathComponent("in\(c + 1).wav")
            let to = rec.folder.appendingPathComponent(String(format: "%02d %@.wav", c + 1, safe))
            try? FileManager.default.moveItem(at: from, to: to)
        }
        lastRecording = rec.folder
    }

    // MARK: - scenes

    /// Built in: everything down, flat, unmuted, default names.  For
    /// resetting between bands; can't be overwritten or deleted.
    static let blankScene = "Blank board"
    /// Saved automatically before every load so a load can be undone.
    static let previousScene = "Previous"

    var scenes: [String] = []   // saved on disk, including Previous

    var userScenes: [String] { scenes.filter { !isReserved($0) } }

    func isReserved(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return [Self.blankScene, Self.previousScene].contains { $0.caseInsensitiveCompare(n) == .orderedSame }
    }

    private static var scenesFolder: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("Scenes", isDirectory: true)
    }

    private static func sceneURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return scenesFolder.appendingPathComponent(safe).appendingPathExtension("json")
    }

    func refreshScenes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.scenesFolder, includingPropertiesForKeys: nil)) ?? []
        scenes = files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func sceneExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.sceneURL(name).path)
    }

    func saveScene(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isReserved(name) else { return }
        writeCurrent(as: name)
        refreshScenes()
    }

    private func writeCurrent(as name: String) {
        try? FileManager.default.createDirectory(at: Self.scenesFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(MixerScene(channels: session.channels, mixes: session.mixes)) {
            try? data.write(to: Self.sceneURL(name), options: .atomic)
        }
    }

    func loadScene(named name: String) {
        let incoming: MixerScene
        if name == Self.blankScene {
            incoming = MixerScene(channels: Session.initial.channels, mixes: Session.initial.mixes)
        } else {
            guard let data = try? Data(contentsOf: Self.sceneURL(name)),
                  var scene = try? JSONDecoder().decode(MixerScene.self, from: data) else { return }
            Mix.migrateNames(&scene.mixes, from: scene.auxNames)
            guard scene.channels.count == channelCount, scene.mixes.count == mixCount else { return }
            FaderScale.migrate(&scene.mixes, from: scene.faderTaper)
            incoming = scene
        }
        // Read first, then save: loading Previous swaps it with the current board.
        writeCurrent(as: Self.previousScene)
        var s = session
        s.channels = incoming.channels
        s.mixes = incoming.mixes
        session = s
        refreshScenes()
    }

    func deleteScene(named name: String) {
        try? FileManager.default.removeItem(at: Self.sceneURL(name))
        refreshScenes()
    }

    // MARK: - persistence

    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VSL Mixer", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    private static func loadSession() -> Session? {
        guard let data = try? Data(contentsOf: stateURL),
              var s = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        Mix.migrateNames(&s.mixes, from: s.auxNames)
        s.auxNames = Mix.currentAuxNames
        guard s.channels.count == channelCount, s.mixes.count == mixCount,
              s.mixes.allSatisfy({ $0.sends.count == channelCount }) else { return nil }
        FaderScale.migrate(&s.mixes, from: s.faderTaper)
        s.faderTaper = FaderScale.currentTaper
        return s
    }

    /// Saves within 0.2 s of any change, and keeps saving at that rate while
    /// a fader is moving, so a crash loses at most the last fraction of a
    /// second.  (A debounce would wait for the movement to stop.)
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    private func saveNow() {
        let url = Self.stateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

import SwiftUI

struct MixerView: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * k) {
            HeaderBar()
            HStack(spacing: 12 * k) {
                HStack(spacing: 8 * k) {
                    ForEach(0..<channelCount, id: \.self) { ChannelStrip(index: $0) }
                }
                MasterStrip()
            }
        }
        .padding(.horizontal, 20 * k)
        .padding(.top, 10 * k)
        .padding(.bottom, 20 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(.easeOut(duration: 0.15), value: app.selectedMix)
    }
}

struct HeaderBar: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 10 * k) {
            MixPicker()
            Spacer(minLength: 16 * k)
            StatusPill()
            if let err = app.recordingError {
                Text(err).uiFont(12).foregroundStyle(Theme.hot)
            } else if app.recording != nil {
                RecordingTimeLeft()
            } else if let last = app.lastRecording {
                Button("Show recording") { NSWorkspace.shared.activateFileViewerSelecting([last]) }
                    .buttonStyle(.link).uiFont(12)
            }
            RecordButton()
            ScenesMenu()
            PhonesButton()
            HeaderButton(title: "Setup") { app.showSetup = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

struct HeaderButton: View {
    @Environment(\.uiScale) private var k
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).uiFont(13).padding(.horizontal, 14 * k).frame(height: 34 * k)
                .background(RoundedRectangle(cornerRadius: 8 * k).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(Theme.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shows at a glance whether phones can connect, and how many have.
struct PhonesButton: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app

    var body: some View {
        let off = app.remoteStatus == .off
        let failed = if case .failed = app.remoteStatus { true } else { false }
        let count = app.remoteConnections.count
        Button { app.showPhones = true } label: {
            HStack(spacing: 6 * k) {
                Image(systemName: off || failed ? "iphone.slash" : "iphone")
                Text(off ? "Phones off" : failed ? "Phones failed" : count == 0 ? "Phones" : "Phones (\(count))")
            }
            .uiFont(13)
            .foregroundStyle(failed ? Theme.hot : off ? Theme.secondary : Theme.text)
            .padding(.horizontal, 14 * k).frame(height: 34 * k)
            .background(RoundedRectangle(cornerRadius: 8 * k).fill(off ? Color.clear : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8 * k)
                .stroke(Theme.control, style: StrokeStyle(lineWidth: 1, dash: off ? [4 * k, 3 * k] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(off ? "Phone control is off. Click to turn it on."
              : failed ? "Phone control couldn't start. Click for details."
              : "Let musicians control their mixes from their phones")
    }
}

struct StatusPill: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.status
        let (dot, title, detail): (Color, String, String) = {
            switch s.state {
            case .starting:
                return (Theme.warn, "Starting audio", "")
            case .running:
                return (Theme.good, "\(s.dropouts) dropout\(s.dropouts == 1 ? "" : "s")", "")
            case .problem(let msg):
                return (Theme.hot, msg, "")
            case .needsPermission:
                return (Theme.hot, "Needs microphone access", "System Settings › Privacy & Security › Microphone")
            }
        }()
        HStack(spacing: 8 * k) {
            Circle().fill(dot).frame(width: 8 * k, height: 8 * k).accessibilityHidden(true)
            Text(title)
            if !detail.isEmpty { Text(detail).foregroundStyle(Theme.secondary) }
        }
        .uiFont(13, mono: true)
        .padding(.horizontal, 14 * k).frame(height: 32 * k)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.control))
        .help(details)
    }
}

extension StatusPill {
    /// The specifics live in the tooltip so the header stays quiet.
    fileprivate var details: String {
        let s = app.status
        guard case .running = s.state else { return "" }
        let rate = s.sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f kHz", s.sampleRate / 1000) : String(format: "%.1f kHz", s.sampleRate / 1000)
        return "Audio running at \(rate) with a \(s.bufferFrames)-sample buffer; about "
            + String(format: "%.1f", s.latencyMs) + " ms from analog input to analog output"
    }
}

struct RecordButton: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    @State private var confirmStop = false

    var body: some View {
        let on = app.recording != nil
        Button {
            if on && seconds > 30 { confirmStop = true } else { app.toggleRecording() }
        } label: {
            HStack(spacing: 8 * k) {
                Circle().fill(on ? Color.white : Theme.hot).frame(width: 10 * k, height: 10 * k)
                Text(on ? "Stop recording \(elapsed)" : "Record inputs")
            }
            .uiFont(13, .semibold, mono: true)
            .padding(.horizontal, 14 * k).frame(height: 34 * k)
            .foregroundStyle(on ? Color.white : Theme.text)
            .background(RoundedRectangle(cornerRadius: 8 * k).fill(on ? Theme.muteRed : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(on ? Theme.muteRed : Theme.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Record every input, before any processing, to its own WAV file")
        .confirmationDialog("Stop recording?", isPresented: $confirmStop) {
            Button("Stop recording", role: .destructive) { app.toggleRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("You've been recording for \(elapsed).")
        }
    }

    private var seconds: Int {
        guard let r = app.recording else { return 0 }
        return max(0, Int(app.now.timeIntervalSince(r.started)))
    }

    private var elapsed: String {
        let s = seconds
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct RecordingTimeLeft: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let left = app.recordingSecondsLeft {
            let text = left >= 3600 ? String(format: "%.1f hr remaining", left / 3600)
                                    : "\(Int(left / 60)) min remaining"
            Text(text)
                .uiFont(12, left < 600 ? .semibold : .regular, mono: true)
                .foregroundStyle(left < 600 ? Theme.hot : Theme.secondary)
                .help("Recording time left before the disk fills or a track's WAV file reaches 4 GB")
        }
    }
}

struct ScenesMenu: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    @State private var saving = false
    @State private var draft = ""
    @State private var toDelete: String?

    var body: some View {
        Menu {
            Button("Save Scene…") { draft = ""; saving = true }
            Section("Load") {
                Button(AppState.blankScene) { app.loadScene(named: AppState.blankScene) }
                if app.scenes.contains(AppState.previousScene) {
                    Button("\(AppState.previousScene) (before last load)") { app.loadScene(named: AppState.previousScene) }
                }
                ForEach(app.userScenes, id: \.self) { name in
                    Button(name) { app.loadScene(named: name) }
                }
            }
            if !app.userScenes.isEmpty {
                Menu("Delete") {
                    ForEach(app.userScenes, id: \.self) { name in
                        Button(name) { toDelete = name }
                    }
                }
            }
        } label: {
            Text("Scenes").uiFont(13).padding(.horizontal, 14 * k).frame(height: 34 * k)
                .background(RoundedRectangle(cornerRadius: 8 * k).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(Theme.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Save scene", isPresented: $saving) {
            TextField("Scene name", text: $draft)
            Button("Save") { app.saveScene(named: draft) }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || app.isReserved(draft))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every level, EQ, compressor, mute and name. Using an existing name replaces that scene. “\(AppState.blankScene)” and “\(AppState.previousScene)” are taken.")
        }
        .alert("Delete “\(toDelete ?? "")”?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Delete", role: .destructive) { if let n = toDelete { app.deleteScene(named: n) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct MixPicker: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 8 * k) {
            ForEach(0..<mixCount, id: \.self) { MixButton(mix: $0) }
        }
    }
}

/// Selects which output the faders drive; press and hold to rename.
struct MixButton: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let mix: Int

    var body: some View {
        let theme = Theme.mixes[mix], sel = mix == app.selectedMix
        let name = app.session.mixes[mix].name
        let renaming = app.editingName == .output(mix)
        Group {
            if renaming {
                VStack(alignment: .leading, spacing: 1 * k) {
                    NameField(initial: name, size: 14,
                              onTab: { app.editingName = Strip.output(mix).neighbor(backward: $0) }) { new in
                        if let new { app.session.mixes[mix].name = new }
                        if app.editingName == .output(mix) { app.editingName = nil }
                    }
                    Text(Session.outputs(ofMix: mix)).uiFont(12).opacity(0.85)
                }
                .padding(.horizontal, 10 * k)
                .frame(width: 150 * k, height: 50 * k, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10 * k).fill(theme.ground))
                .overlay(RoundedRectangle(cornerRadius: 10 * k).stroke(theme.ink, lineWidth: 2))
            } else {
                Button { app.selectedMix = mix } label: {
                    VStack(alignment: .leading, spacing: 1 * k) {
                        Text(name).uiFont(14, .semibold).lineLimit(1)
                        Text(Session.outputs(ofMix: mix)).uiFont(12).opacity(0.85)
                    }
                    .padding(.horizontal, 14 * k)
                    .frame(minWidth: 104 * k, minHeight: 50 * k, alignment: .leading)
                    .foregroundStyle(sel ? Color.black : Theme.text)
                    .background(RoundedRectangle(cornerRadius: 10 * k).fill(sel ? theme.ink : theme.ground))
                    .overlay(RoundedRectangle(cornerRadius: 10 * k).stroke(theme.ink.opacity(sel ? 1 : 0.6), lineWidth: 2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in app.editingName = .output(mix) })
                .contextMenu { Button("Rename") { app.editingName = .output(mix) } }
                .keyboardShortcut(KeyEquivalent(Character(String(mix + 1))), modifiers: .command)
                .accessibilityAddTraits(sel ? .isSelected : [])
                .help("Show \(name) on the faders (⌘\(mix + 1)). Press and hold to rename.")
            }
        }
    }
}

struct ChannelStrip: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let index: Int

    var body: some View {
        let ch = app.session.channels[index]
        let mix = app.selectedMix
        let theme = Theme.mixes[mix]
        let level = Binding(
            get: { app.session.mixes[mix].sends[index] },
            set: { app.session.mixes[mix].sends[index] = $0 })
        let muted = Binding(
            get: { app.session.channels[index].muted },
            set: { app.session.channels[index].muted = $0 })
        let name = Binding(
            get: { app.session.channels[index].name },
            set: { app.session.channels[index].name = $0 })

        VStack(alignment: .leading, spacing: 10 * k) {
            VStack(alignment: .leading, spacing: 1 * k) {
                Text("In \(index + 1)").uiFont(12).foregroundStyle(Theme.secondary)
                EditableName(text: name, size: 15, strip: .input(index))
            }
            MiniCurveButton(label: "EQ", active: ch.eqActive, tint: .white,
                            reference: HorizontalLine(), curve: MiniEQShape(settings: ch),
                            help: "Edit \(ch.name) EQ") { app.route = .eq(.input(index)) }
            MiniCurveButton(label: "Comp", active: ch.compActive, tint: .white,
                            reference: UnityLine(), curve: MiniCompShape(settings: ch),
                            help: "Edit \(ch.name) compressor") { app.route = .comp(.input(index)) }
            HStack(spacing: 8 * k) {
                // Only this box belongs to the selected output.
                VStack(spacing: 8 * k) {
                    FaderView(value: level, tint: theme.ink,
                              accessibilityName: "\(ch.name) level in \(app.session.mixes[mix].name)")
                    Text(FaderScale.label(level.wrappedValue))
                        .uiFont(13, mono: true)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 8 * k)
                .background(RoundedRectangle(cornerRadius: 10 * k).fill(theme.ground))
                .overlay(RoundedRectangle(cornerRadius: 10 * k).stroke(theme.ink.opacity(0.6), lineWidth: 1.5))
                MeterWithClip(db: app.meters.input[index], clipped: Binding(
                    get: { app.meters.inputClipped[index] }, set: { app.meters.inputClipped[index] = $0 }),
                    what: "\(ch.name)'s input")
                    .padding(.vertical, 8 * k)
            }
            .frame(maxHeight: .infinity)
            MuteButton(muted: muted)
        }
        .padding(10 * k)
        .frame(minWidth: 112 * k, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12 * k).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12 * k).stroke(Theme.border))
    }
}

struct MasterStrip: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app

    var body: some View {
        let mix = app.selectedMix
        let theme = Theme.mixes[mix]
        let name = app.session.mixes[mix].name
        let fx = app.session.mixes[mix].processing
        let level = Binding(
            get: { app.session.mixes[mix].master },
            set: { app.session.mixes[mix].master = $0 })
        let muted = Binding(
            get: { app.session.mixes[mix].processing.muted },
            set: { app.session.mixes[mix].processing.muted = $0 })
        VStack(alignment: .leading, spacing: 10 * k) {
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(Session.outputs(ofMix: mix)).uiFont(12).foregroundStyle(Theme.secondary)
                Text(name).uiFont(15, .semibold)
                    .foregroundStyle(theme.ink).lineLimit(1)
            }
            MiniCurveButton(label: "EQ", active: fx.eqActive, tint: theme.ink,
                            reference: HorizontalLine(), curve: MiniEQShape(settings: fx),
                            help: "Edit \(name) EQ") { app.route = .eq(.output(mix)) }
            MiniCurveButton(label: "Comp", active: fx.compActive, tint: theme.ink,
                            reference: UnityLine(), curve: MiniCompShape(settings: fx),
                            help: "Edit \(name) compressor") { app.route = .comp(.output(mix)) }
            DelayButton(mix: mix)
            HStack(spacing: 8 * k) {
                FaderView(value: level, tint: theme.ink, accessibilityName: "\(name) level")
                MeterWithClip(db: app.meters.mix[mix], clipped: Binding(
                    get: { app.meters.mixClipped[mix] }, set: { app.meters.mixClipped[mix] = $0 }),
                    what: name)
            }
            .padding(.vertical, 8 * k)
            .frame(maxHeight: .infinity)
            Text(FaderScale.label(level.wrappedValue))
                .uiFont(13, mono: true)
                .frame(maxWidth: .infinity)
            MuteButton(muted: muted, help: Theme.muteHelp(.output(mix)))
        }
        .padding(10 * k)
        .frame(width: 150 * k)
        .background(RoundedRectangle(cornerRadius: 12 * k).fill(theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 12 * k).stroke(theme.ink, lineWidth: 2))
    }
}

/// An output's delay, in ms and feet; click to change it.
struct DelayButton: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let mix: Int
    @State private var editing = false

    var body: some View {
        let ms = app.session.mixes[mix].delayMs
        let theme = Theme.mixes[mix]
        Button { editing = true } label: {
            HStack(spacing: 6 * k) {
                Text("Delay").font(.system(size: 11 * k)).foregroundStyle(Theme.secondary)
                    .frame(width: 34 * k, alignment: .leading)
                Spacer(minLength: 0)
                if ms > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.1f ms", ms))
                        Text(String(format: "%.1f ft", ms * Mix.feetPerMs)).foregroundStyle(Theme.secondary)
                    }
                    .uiFont(11, .semibold, mono: true)
                    .foregroundStyle(theme.ink)
                } else {
                    Text("Off").uiFont(11, .semibold).foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 7 * k).frame(height: 34 * k)
            .background(RoundedRectangle(cornerRadius: 8 * k).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(Theme.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Delay \(app.session.mixes[mix].name) to line it up with speakers further away")
        .accessibilityLabel("\(app.session.mixes[mix].name) delay")
        .accessibilityValue(ms > 0 ? DelayButton.label(ms) : "off")
        .popover(isPresented: $editing, arrowEdge: .leading) { DelayEditor(mix: mix) }
    }

    static func label(_ ms: Double) -> String {
        String(format: "%.1f ms · %.1f ft", ms, ms * Mix.feetPerMs)
    }
}

struct DelayEditor: View {
    @Environment(AppState.self) private var app
    let mix: Int

    var body: some View {
        let delay = Binding(
            get: { app.session.mixes[mix].delayMs },
            set: { app.session.mixes[mix].delayMs = min(Mix.maxDelayMs, max(0, ($0 * 10).rounded() / 10)) })
        let feet = Binding(
            get: { delay.wrappedValue * Mix.feetPerMs },
            set: { delay.wrappedValue = $0 / Mix.feetPerMs })
        VStack(alignment: .leading, spacing: 12) {
            Text("\(app.session.mixes[mix].name) delay").font(.headline)
            Text("Delay this output so it arrives with sound from speakers further away. Enter the extra distance in feet, or the time in milliseconds.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { delay.wrappedValue = (delay.wrappedValue - 1).rounded() } label: { Image(systemName: "minus") }
                    .accessibilityLabel("1 ms less")
                Slider(value: delay, in: 0...Mix.maxDelayMs)
                Button { delay.wrappedValue = (delay.wrappedValue + 1).rounded() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("1 ms more")
            }
            HStack(spacing: 16) {
                field("ms", value: delay)
                field("ft", value: feet)
                Spacer()
                Button("Off") { delay.wrappedValue = 0 }.disabled(delay.wrappedValue == 0)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func field(_ unit: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            TextField(unit, value: value, format: .number.precision(.fractionLength(1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

struct SetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [(name: String, uid: String)] = []

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Form {
                Section("Audio interface") {
                    Picker("Interface", selection: $app.session.deviceUID) {
                        // The AudioBox is stored as "" rather than by its device ID,
                        // because macOS bakes the USB port into that ID.
                        if !devices.contains(where: { isAudioBox($0.name) }) {
                            Text("AudioBox 1818VSL (not connected)").tag("")
                        }
                        ForEach(devices, id: \.uid) { d in
                            Text(d.name).tag(isAudioBox(d.name) ? "" : d.uid)
                        }
                    }
                    Picker("Sample rate", selection: $app.session.sampleRate) {
                        ForEach([44100.0, 48000, 88200, 96000], id: \.self) { r in
                            Text(r.truncatingRemainder(dividingBy: 1000) == 0
                                 ? String(format: "%.0f kHz", r / 1000) : String(format: "%.1f kHz", r / 1000)).tag(r)
                        }
                    }
                    Picker("Buffer size", selection: $app.session.bufferFrames) {
                        ForEach([16, 32, 64, 128, 256], id: \.self) { Text("\($0) samples").tag($0) }
                    }
                    Text("Smaller buffers mean less delay but more risk of dropouts. 48 kHz with 16 or 32 samples tested reliably with the AudioBox plugged directly into this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Jammer") {
                    Toggle("Inputs 1–2 from Jammer", isOn: jammerLink)
                    Text(jammerNote).font(.caption).foregroundStyle(.secondary)
                }
                Section("Input names") {
                    ForEach(0..<channelCount, id: \.self) { c in
                        TextField("In \(c + 1)", text: $app.session.channels[c].name)
                    }
                }
                Section("Outputs") {
                    Toggle("Outs 1 and 2 as Aux 1 and Aux 2", isOn: splitMain)
                    Text(app.session.splitMain == true
                         ? "Outs 1 and 2 are separate mono mixes, each with its own faders."
                         : "Main plays out of both outs 1 and 2.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(app.session.shownMixes, id: \.self) { m in
                        TextField(app.session.outputs(ofMix: m), text: $app.session.mixes[m].name)
                    }
                }
                Section("Recording") {
                    LabeledContent("Saved to", value: "Music › VSL Mixer")
                    Button("Open recordings folder") {
                        let url = AppState.recordingsFolder
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 680)
        .onAppear { devices = app.availableDevices() }
    }

    private func isAudioBox(_ name: String) -> Bool { name.contains("1818") }

    /// Turning it on names inputs 1 and 2 for Jammer, unless they've been named already.
    private var jammerLink: Binding<Bool> {
        Binding(get: { app.session.jammerLink == true }, set: { on in
            var s = app.session
            s.jammerLink = on
            if on {
                for (c, side) in ["L", "R"].enumerated() where s.channels[c].name == "Input \(c + 1)" {
                    s.channels[c].name = "Jammer \(side)"
                }
            }
            app.session = s
        })
    }

    /// Main's name follows it ("Main" ↔ "Aux 1") unless it's been named already.
    private var splitMain: Binding<Bool> {
        Binding(get: { app.session.splitMain == true }, set: { on in
            var s = app.session
            if s.mixes[0].name == Session.defaultName(ofMix: 0, split: !on) {
                s.mixes[0].name = Session.defaultName(ofMix: 0, split: on)
            }
            s.splitMain = on
            if !on {
                if app.selectedMix == 1 { app.selectedMix = 0 }
                if app.route == .eq(.output(1)) || app.route == .comp(.output(1)) { app.route = .mixer }
            }
            app.session = s
        })
    }

    private var jammerNote: String {
        if app.session.jammerLink != true {
            return "Jammer's main left and right can come in on inputs 1 and 2 in place of the jacks. Jammer still hears the real inputs 1 and 2."
        }
        if app.jammerLinkFailed { return "Couldn't open the connection to Jammer." }
        if app.status.jammerAlive { return "Jammer is playing into inputs 1 and 2." }
        return "Waiting for Jammer. Set its audio output to the AudioBox and it plays into inputs 1 and 2 instead of out of the jacks."
    }
}

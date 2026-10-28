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
                Section("Outputs") {
                    ForEach(0..<pairCount, id: \.self) { p in
                        Toggle(p == 0 ? "Outs 1+2 as Main" : "Outs \(2 * p + 1)+\(2 * p + 2) as one stereo mix",
                               isOn: linked(p))
                    }
                    Text("Linked outs play one stereo mix, left on the odd out and right on the even one, with a pan for each input. Use them for in-ear monitors. Unlinked, each out is its own mono mix\(app.session.isLinked(pair: 0) ? "" : ", and outs 1 and 2 are Aux 1 and Aux 2"). Linking or unlinking turns levels into pans and back, so both outs keep sounding the same, except that linking drops the even out's own EQ, compressor, delay and limit.")
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
                Section("Output names") {
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

    /// Linking hides the odd out's mix, so leave anything showing it.
    private func linked(_ p: Int) -> Binding<Bool> {
        Binding(get: { app.session.isLinked(pair: p) }, set: { on in
            var s = app.session
            s.link(pair: p, on)
            app.leaveHiddenMixes(in: s)
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

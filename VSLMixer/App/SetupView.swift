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
                Section("Input names") {
                    ForEach(0..<channelCount, id: \.self) { c in
                        TextField("In \(c + 1)", text: $app.session.channels[c].name)
                    }
                }
                Section("Output names") {
                    ForEach(0..<mixCount, id: \.self) { m in
                        TextField(Session.outputs(ofMix: m), text: $app.session.mixes[m].name)
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
}

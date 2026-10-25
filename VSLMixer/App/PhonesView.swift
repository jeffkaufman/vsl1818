import CoreImage.CIFilterBuiltins
import SwiftUI

/// Everything needed to get phones onto the mixer: a QR code to join the
/// Wi-Fi, one per aux for musicians, and one for the whole board.
struct PhonesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var addresses: [String] = []

    var body: some View {
        @Bindable var app = app
        let enabled = Binding(get: { app.session.remoteEnabled == true },
                              set: { app.session.remoteEnabled = $0 })
        let wifiName = Binding(get: { app.session.wifiName ?? "" },
                               set: { app.session.wifiName = $0.isEmpty ? nil : $0 })
        let wifiPassword = Binding(get: { app.session.wifiPassword ?? "" },
                                   set: { app.session.wifiPassword = $0.isEmpty ? nil : $0 })
        let base = baseURL

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Phones").font(.title2.bold())
                Spacer()
                Toggle("Allow phones to connect", isOn: enabled).toggleStyle(.switch)
            }
            statusLine(base)

            if let base {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Join the Wi-Fi").font(.headline)
                        if let name = app.session.wifiName {
                            QRCode(text: wifiQR(name: name, password: app.session.wifiPassword))
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                                .frame(width: QRCode.outerSize, height: QRCode.outerSize)
                                .overlay(Text("Enter the network\nbelow for a QR code")
                                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary))
                        }
                        TextField("Network name", text: wifiName).frame(width: QRCode.outerSize)
                        SecureField("Password", text: wifiPassword).frame(width: QRCode.outerSize)
                    }
                    .frame(width: QRCode.outerSize, alignment: .leading)

                    Divider()

                    // One code for everyone: the page opens on a list of mixes,
                    // plus the whole board behind the passcode.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. Open the mixer").font(.headline)
                        QRCode(text: base)
                        Text("Then pick your mix.").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("Whole board passcode \(app.session.remoteCode ?? "")")
                                .font(.caption.monospacedDigit().bold())
                            Button("New") { app.session.remoteCode = AppState.newPasscode() }
                                .controlSize(.small)
                                .help("Phones already showing the whole board will need the new passcode")
                        }
                    }
                }
            }

            Text("Phones need to be on the same network as this Mac. With no venue Wi-Fi, use a pocket travel router, or make this Mac a hotspot in System Settings › General › Sharing › Internet Sharing (share from any port, to Wi-Fi). Phones may warn there's no internet; tell them to stay connected.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { addresses = RemoteServer.localAddresses() }
    }

    private var baseURL: String? {
        guard case .running(let port) = app.remoteStatus, let ip = addresses.first else { return nil }
        return "http://\(ip):\(port)"
    }

    @ViewBuilder private func statusLine(_ base: String?) -> some View {
        let connected = app.remoteConnections
        switch app.remoteStatus {
        case .running:
            if let base {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phones open \(base)").font(.body.monospaced()).textSelection(.enabled)
                    Text(connected.isEmpty ? "No phones connected"
                                           : "Connected: " + connected.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This Mac isn't on a network. Join Wi-Fi, or turn on Internet Sharing.")
                    .foregroundStyle(Theme.hot)
            }
        case .starting:
            Text("Starting…").foregroundStyle(.secondary)
        case .failed(let why):
            Text("Couldn't start: \(why)").foregroundStyle(Theme.hot)
        case .off:
            Text("Phone control is off. Turn it on to let musicians run their mixes from their phones. The first time, macOS asks to let VSL Mixer find devices on your local network: choose Allow, or phones won't be able to connect.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The standard format phone cameras understand for joining a network.
    private func wifiQR(name: String, password: String?) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        if let password, !password.isEmpty { return "WIFI:T:WPA;S:\(esc(name));P:\(esc(password));;" }
        return "WIFI:T:nopass;S:\(esc(name));;"
    }
}

struct QRCode: View {
    let text: String
    var size: CGFloat = 150
    static let margin: CGFloat = 8
    static let outerSize: CGFloat = 150 + 2 * margin

    var body: some View {
        Group {
            if let image = Self.render(text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.gray
            }
        }
        .frame(width: size, height: size)
        .padding(Self.margin)
        .background(Color.white)   // cameras need a light quiet zone around the code
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(text.hasPrefix("WIFI:") ? "Scan to join the Wi-Fi" : text)
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

struct MixTheme {
    let ground: Color   // window background while this output is selected
    let ink: Color      // accent for its faders and labels
}

enum Theme {
    // Main is grey and each aux has its own color at the same perceived
    // lightness (OKLCH L 0.33, chroma 0.045), so none stands out or recedes.  Only the parts of the
    // window that belong to one output take its color, so it's always obvious
    // which output the faders drive and that mute and processing don't vary.
    static let mixes: [MixTheme] = [
        MixTheme(ground: Color(hex: 0x34363C), ink: Color(hex: 0xFFFFFF)),
        MixTheme(ground: Color(hex: 0x26374D), ink: Color(hex: 0x7FB2FF)),
        MixTheme(ground: Color(hex: 0x253D2A), ink: Color(hex: 0x5BD495)),
        MixTheme(ground: Color(hex: 0x3A314A), ink: Color(hex: 0xBE9BFF)),
        MixTheme(ground: Color(hex: 0x48301F), ink: Color(hex: 0xFFAE6B)),
        MixTheme(ground: Color(hex: 0x143D3F), ink: Color(hex: 0x4FD6DC)),
        MixTheme(ground: Color(hex: 0x492C37), ink: Color(hex: 0xFF86B0)),
    ]

    static let background = Color(hex: 0x16171A)
    static let text = Color(hex: 0xEDEEF0)
    static let secondary = Color.white.opacity(0.68)
    static let panel = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.22)
    static let control = Color.white.opacity(0.3)   // outlines on buttons
    static let well = Color(hex: 0x0B0C0E)
    static let muteRed = Color(hex: 0xC62F35)
    static let good = Color(hex: 0x3DD68C)
    static let warn = Color(hex: 0xF5D90A)
    static let hot = Color(hex: 0xFF5C5C)
    static let gr = Color(hex: 0xFFAE6B)

    static let bands: [Color] = [Color(hex: 0xFFAE6B), Color(hex: 0x7FB2FF),
                                 Color(hex: 0x5BD495), Color(hex: 0xFF86B0)]
}

/// Everything is laid out for a 1440x900 window and scaled up from there, so
/// the mixer stays readable full screen on a big display.
private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var k
    let size: CGFloat
    let weight: Font.Weight
    let mono: Bool

    func body(content: Content) -> some View {
        let f = Font.system(size: size * k, weight: weight)
        return content.font(mono ? f.monospacedDigit() : f)
    }
}

extension View {
    func uiFont(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, mono: mono))
    }
}

/// Pill-shaped on/off toggle used for processing sections.
struct PillToggle: View {
    @Environment(\.uiScale) private var k
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text("\(title) \(isOn ? "on" : "off")")
                .uiFont(12, .semibold)
                .padding(.horizontal, 14 * k)
                .frame(height: 30 * k)
                .foregroundStyle(isOn ? Color.black : Theme.text)
                .background(Capsule().fill(isOn ? Color.white : Theme.panel))
                .overlay(Capsule().stroke(isOn ? Color.white : Theme.control))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

struct MuteButton: View {
    @Environment(\.uiScale) private var k
    @Binding var muted: Bool
    var height: CGFloat = 44

    var body: some View {
        Button { muted.toggle() } label: {
            Text(muted ? "Muted" : "Mute")
                .uiFont(13, .semibold)
                .frame(maxWidth: .infinity, minHeight: height * k)
                .foregroundStyle(muted ? .white : Theme.text)
                .background(RoundedRectangle(cornerRadius: 8 * k).fill(muted ? Theme.muteRed : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(muted ? Theme.muteRed : Theme.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mutes this input in every output")
        .accessibilityAddTraits(muted ? .isSelected : [])
    }
}

struct ResetButton: View {
    @Environment(\.uiScale) private var k
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).uiFont(12, .semibold)
                .padding(.horizontal, 14 * k).frame(height: 30 * k)
                .background(Capsule().fill(Theme.panel))
                .overlay(Capsule().stroke(Theme.control))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A text field for renaming in place.  Return or clicking anywhere else
/// saves; Escape cancels.
struct NameField: View {
    @Environment(\.uiScale) private var k
    let initial: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    let done: (String?) -> Void

    @State private var draft = ""
    @State private var finished = false
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .uiFont(size, weight)
            .focused($focused)
            .padding(.horizontal, 4 * k)
            .background(RoundedRectangle(cornerRadius: 4 * k).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 4 * k).stroke(Color.white.opacity(0.6)))
            .onAppear {
                draft = initial
                DispatchQueue.main.async { focused = true }
                watchClicksElsewhere()
            }
            .onDisappear { stopWatching() }
            .onSubmit { finish() }
            .onExitCommand { end(nil) }
            .onChange(of: focused) { _, f in if !f { finish() } }
    }

    private func finish() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        end(t.isEmpty ? nil : t)
    }

    private func end(_ result: String?) {
        guard !finished else { return }
        finished = true
        stopWatching()
        done(result)
    }

    // Plain buttons and faders don't take keyboard focus, so clicking them
    // wouldn't end editing on its own.  Watch for any click outside the
    // field (the field's editor is the window's first responder) and save.
    // The click still goes through to whatever was clicked.
    private func watchClicksElsewhere() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let window = event.window,
               let editor = window.firstResponder as? NSView,
               let hit = window.contentView?.hitTest(event.locationInWindow),
               hit === editor || hit.isDescendant(of: editor) {
                return event
            }
            DispatchQueue.main.async { finish() }
            return event
        }
    }

    private func stopWatching() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}

/// A name you rename by clicking it, pressing and holding it, or from its
/// context menu.
struct EditableName: View {
    @Binding var text: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    @State private var editing = false

    var body: some View {
        if editing {
            NameField(initial: text, size: size, weight: weight) { new in
                if let new { text = new }
                editing = false
            }
        } else {
            Text(text).uiFont(size, weight).lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { editing = true }
                .onLongPressGesture(minimumDuration: 0.5) { editing = true }
                .contextMenu { Button("Rename") { editing = true } }
                .help("Click to rename")
        }
    }
}

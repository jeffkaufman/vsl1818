import SwiftUI

/// Vertical fader.  Dragging is always relative to where the thumb was, so a
/// stray click on the track never jumps a level during a show.  Hold Option
/// for fine control.
struct FaderView: View {
    @Environment(\.uiScale) private var k
    @Binding var value: Double
    var tint: Color
    var accessibilityName: String

    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 28 * k
            let travel = max(1, geo.size.height - thumb)
            let y = (1 - value) * travel
            ZStack(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.55)).frame(width: 6 * k)
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: 6 * k, height: max(0, geo.size.height - y - thumb / 2))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                RoundedRectangle(cornerRadius: 5 * k)
                    .fill(Color(white: 0.86))
                    .frame(width: 76 * k, height: thumb)
                    .overlay(Rectangle().fill(focused ? tint : Color.black.opacity(0.6)).frame(height: 2 * k))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                        value = min(1, max(0, dragStart! - g.translation.height / travel * fine))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(minWidth: 80 * k)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { nudge(0.01); return .handled }
        .onKeyPress(.downArrow) { nudge(-0.01); return .handled }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(FaderScale.label(value))
        .accessibilityAdjustableAction { dir in
            nudge(dir == .increment ? 0.01 : -0.01)
        }
    }

    private func nudge(_ d: Double) { value = min(1, max(0, value + d)) }
}

/// Peak meter, −60…0 dBFS.
struct MeterBar: View {
    @Environment(\.uiScale) private var k
    var db: Double
    var dim = false
    var horizontal = false
    var thickness: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            let gradient = LinearGradient(
                stops: [.init(color: Theme.good, location: 0), .init(color: Theme.good, location: 0.7),
                        .init(color: Theme.warn, location: 0.87), .init(color: Theme.hot, location: 1)],
                startPoint: horizontal ? .leading : .bottom, endPoint: horizontal ? .trailing : .top)
            ZStack(alignment: horizontal ? .trailing : .top) {
                gradient
                Rectangle().fill(Theme.well)
                    .frame(width: horizontal ? g.size.width * (1 - frac) : nil,
                           height: horizontal ? nil : g.size.height * (1 - frac))
            }
        }
        .frame(width: horizontal ? nil : thickness * k, height: horizontal ? thickness * k : nil)
        .clipShape(Capsule())
        .opacity(dim ? 0.35 : 1)
        .accessibilityHidden(true)
    }
}

/// A meter with a clip light on top.  The light stays red after a clip
/// until the meter or light is clicked.
struct MeterWithClip: View {
    @Environment(\.uiScale) private var k
    var db: Double
    @Binding var clipped: Bool
    var what: String

    var body: some View {
        VStack(spacing: 4 * k) {
            RoundedRectangle(cornerRadius: 2 * k)
                .fill(clipped ? Theme.hot : Color.white.opacity(0.12))
                .frame(width: 8 * k, height: 12 * k)
            MeterBar(db: db)
        }
        .contentShape(Rectangle())
        .onTapGesture { clipped = false }
        .help(clipped ? "\(what) clipped. Click to clear." : "Lights red if \(what) clips")
        .accessibilityElement()
        .accessibilityLabel(clipped ? "\(what) clipped" : "\(what) not clipped")
        .accessibilityAddTraits(clipped ? .isButton : [])
        .accessibilityAction { clipped = false }
    }
}

/// The channel's whole high-pass + EQ curve, ±18 dB.
struct MiniEQShape: Shape {
    var settings: ChannelSettings

    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 0...60 {
            let x = Double(i) / 60
            let f = 20 * pow(1000, x)
            let db = max(-18, min(18, settings.eqResponse(at: f)))
            let pt = CGPoint(x: r.minX + x * r.width, y: r.midY - db / 18 * r.height / 2)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// The compressor's transfer curve: input −60…0 dB across, output −60…+12 dB up.
struct MiniCompShape: Shape {
    var settings: ChannelSettings

    func path(in r: CGRect) -> Path {
        func pt(_ input: Double) -> CGPoint {
            let out = max(-60, min(12, settings.compOutput(forInput: input)))
            return CGPoint(x: r.minX + (input + 60) / 60 * r.width, y: r.minY + (12 - out) / 72 * r.height)
        }
        var p = Path()
        p.move(to: pt(-60))
        p.addLine(to: pt(settings.thresholdDb))
        p.addLine(to: pt(0))
        return p
    }
}

/// Clickable summary row on a channel strip.
struct MiniCurveButton<S: Shape, Ref: Shape>: View {
    @Environment(\.uiScale) private var k
    let label: String
    let active: Bool
    let tint: Color
    let reference: Ref
    let curve: S
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * k) {
                Text(label).font(.system(size: 11 * k)).foregroundStyle(Theme.secondary).frame(width: 34 * k, alignment: .leading)
                ZStack {
                    reference.stroke(Color.white.opacity(0.18), lineWidth: 1)
                    curve.stroke(active ? tint : Color.white.opacity(0.35), lineWidth: 1.75)
                }
                .frame(height: 24 * k)
            }
            .padding(.horizontal, 7 * k).padding(.vertical, 5 * k)
            .background(RoundedRectangle(cornerRadius: 8 * k).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(Theme.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HorizontalLine: Shape {
    func path(in r: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
    }
}

struct UnityLine: Shape {
    // unity in the −60…+12 output range used by MiniCompShape
    func path(in r: CGRect) -> Path {
        Path {
            $0.move(to: CGPoint(x: r.minX, y: r.maxY))
            $0.addLine(to: CGPoint(x: r.maxX, y: r.minY + 12.0 / 72 * r.height))
        }
    }
}

import SwiftUI

/// Every input's spectrum at once, for finding which mic is feeding back.
/// Hovering any plot shows that frequency on all of them and picks out the
/// input that's loudest there; a steady narrow peak is marked on its own.
/// Clicking an input opens its EQ.
struct FeedbackView: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    @State private var hoverHz: Double?

    var body: some View {
        let loudest = loudestInput()
        VStack(alignment: .leading, spacing: 14 * k) {
            HStack(spacing: 16 * k) {
                Button { app.route = .mixer } label: {
                    Label("Mixer", systemImage: "chevron.left")
                        .uiFont(13).padding(.horizontal, 14 * k).frame(height: 34 * k)
                        .background(RoundedRectangle(cornerRadius: 8 * k).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(Theme.control))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                Text("Feedback").uiFont(20, .semibold)
                Text("Each input before EQ. Point at the pitch you hear to see which input is loudest there. A steady narrow peak is marked in red. Click an input to open its EQ.")
                    .uiFont(13).foregroundStyle(Theme.secondary)
                Spacer()
            }
            Grid(horizontalSpacing: 10 * k, verticalSpacing: 10 * k) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<4, id: \.self) { col in
                            let c = row * 4 + col
                            SpectrumTile(index: c, spectrum: app.inputSpectra[c],
                                         hoverHz: $hoverHz, loudest: c == loudest)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20 * k).padding(.top, 10 * k).padding(.bottom, 20 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// The input with the most energy at the hovered frequency, if any has some.
    private func loudestInput() -> Int? {
        guard let f = hoverHz else { return nil }
        let levels = app.inputSpectra.map { $0.level(from: f / 1.03, to: f * 1.03) ?? -200 }
        guard let best = levels.indices.max(by: { levels[$0] < levels[$1] }), levels[best] > -80 else { return nil }
        return best
    }
}

private struct SpectrumTile: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let index: Int
    let spectrum: Spectrum
    @Binding var hoverHz: Double?
    let loudest: Bool

    var body: some View {
        let _ = spectrum.bins   // redraw as it updates
        let steady = spectrum.steadyHz
        Button { app.route = .eq(.input(index)) } label: {
            VStack(alignment: .leading, spacing: 6 * k) {
                HStack(alignment: .lastTextBaseline, spacing: 8 * k) {
                    VStack(alignment: .leading, spacing: 1 * k) {
                        Text("In \(index + 1)").uiFont(12).foregroundStyle(Theme.secondary)
                        Text(app.session.channels[index].name).uiFont(15, .semibold).lineLimit(1)
                    }
                    Spacer(minLength: 4 * k)
                    if let f = hoverHz, let db = spectrum.level(from: f / 1.03, to: f * 1.03) {
                        Text(String(format: "%.0f dB at %@", db, hzLabel(f)))
                            .uiFont(12, mono: true).foregroundStyle(loudest ? Theme.text : Theme.secondary)
                    } else if let f = steady {
                        Text("Steady \(hzLabel(f))").uiFont(12, .semibold).foregroundStyle(Theme.hot)
                    }
                }
                GeometryReader { g in
                    Canvas { ctx, size in draw(ctx, size, steady: steady) }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hoverHz = Self.f(p.x, width: g.size.width)
                            case .ended: hoverHz = nil
                            }
                        }
                }
                .background(RoundedRectangle(cornerRadius: 6 * k).fill(Theme.well))
                .clipShape(RoundedRectangle(cornerRadius: 6 * k))
            }
            .padding(10 * k)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10 * k).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10 * k)
                .stroke(loudest ? Theme.text : steady != nil ? Theme.hot : Theme.border,
                        lineWidth: loudest || steady != nil ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(app.session.channels[index].name) EQ")
    }

    // 20 Hz to 20 kHz across, −90 to 0 dBFS up, like the EQ editor's spectrum.
    static func x(_ f: Double, width: CGFloat) -> CGFloat { width * log(f / 20) / log(1000) }
    static func f(_ x: CGFloat, width: CGFloat) -> Double { 20 * pow(1000, Double(x / max(1, width))) }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, steady: Double?) {
        let w = size.width, h = size.height
        func y(_ dbfs: Double) -> CGFloat { h * CGFloat(min(1, max(0, -dbfs / 90))) }

        for (f, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            let x = Self.x(f, width: w)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(.white.opacity(0.08)), lineWidth: 1)
            ctx.draw(Text(label).font(.system(size: 10 * k)).foregroundStyle(Theme.secondary.opacity(0.7)),
                     at: CGPoint(x: x + 3 * k, y: h - 3 * k), anchor: .bottomLeading)
        }

        var line = Path(), fill = Path()
        fill.move(to: CGPoint(x: 0, y: h))
        let step: CGFloat = 2
        var started = false
        for x in stride(from: CGFloat(0), through: w, by: step) {
            guard let level = spectrum.level(from: Self.f(x, width: w), to: Self.f(x + step, width: w))
            else { continue }
            let p = CGPoint(x: x, y: y(Double(level)))
            if started { line.addLine(to: p) } else { line.move(to: p); started = true }
            fill.addLine(to: p)
        }
        if started {
            fill.addLine(to: CGPoint(x: w, y: h))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(.white.opacity(0.12)))
            ctx.stroke(line, with: .color(.white.opacity(0.55)), lineWidth: 1)
        }

        if let f = steady {
            let x = Self.x(f, width: w)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(Theme.hot.opacity(0.8)), lineWidth: 2)
        }
        if let f = hoverHz {
            let x = Self.x(f, width: w)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
    }
}

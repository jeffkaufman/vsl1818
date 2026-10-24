import SwiftUI

enum EditorTab { case eq, comp }

struct ChannelEditorView: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let channel: Int
    let tab: EditorTab

    var body: some View {
        let muted = Binding(get: { app.session.channels[channel].muted },
                            set: { app.session.channels[channel].muted = $0 })
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
                VStack(alignment: .leading, spacing: 1 * k) {
                    Text("In \(channel + 1)").font(.system(size: 12 * k)).foregroundStyle(Theme.secondary)
                    EditableName(text: Binding(get: { app.session.channels[channel].name },
                                               set: { app.session.channels[channel].name = $0 }), size: 20)
                }
                HStack(spacing: 4 * k) {
                    tabButton("EQ", selected: tab == .eq) { app.route = .eq(channel) }
                    tabButton("Compressor", selected: tab == .comp) { app.route = .comp(channel) }
                }
                .padding(3 * k)
                .background(RoundedRectangle(cornerRadius: 10 * k).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 10 * k).stroke(Theme.control))
                Spacer()
                HStack(spacing: 8 * k) {
                    Text("Input").font(.system(size: 12 * k)).foregroundStyle(Theme.secondary)
                    MeterBar(db: app.meters.input[channel], horizontal: true).frame(width: 180 * k)
                }
                MuteButton(muted: muted, height: 34 * k).frame(width: 90 * k)
            }
            switch tab {
            case .eq: EQEditor(channel: channel)
            case .comp: CompEditor(channel: channel)
            }
        }
        .padding(.horizontal, 20 * k).padding(.top, 10 * k).padding(.bottom, 20 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).uiFont(13, .semibold)
                .padding(.horizontal, 16 * k).frame(height: 32 * k)
                .foregroundStyle(selected ? Color.black : Theme.text)
                .background(RoundedRectangle(cornerRadius: 8 * k).fill(selected ? Color.white : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - EQ

private enum Band: Int, CaseIterable, Identifiable {
    case hpf, low, mid, high
    var id: Int { rawValue }

    var name: String { ["High-pass", "Low shelf", "Mid", "High shelf"][rawValue] }
    var color: Color { Theme.bands[rawValue] }
    var range: ClosedRange<Double> { [20.0...400, 30...500, 150...8000, 1500...18000][rawValue] }

    func freq(_ s: ChannelSettings) -> Double { [s.hpfHz, s.lowHz, s.midHz, s.highHz][rawValue] }
    func gain(_ s: ChannelSettings) -> Double? { [nil, s.lowDb, s.midDb, s.highDb][rawValue] }
    func isOn(_ s: ChannelSettings) -> Bool { self != .hpf || s.hpfActive }

    func set(_ s: inout ChannelSettings, freq: Double, gain: Double) {
        let f = min(range.upperBound, max(range.lowerBound, freq))
        let g = min(18, max(-18, gain))
        switch self {
        case .hpf: s.hpfHz = f
        case .low: s.lowHz = f; s.lowDb = g
        case .mid: s.midHz = f; s.midDb = g
        case .high: s.highHz = f; s.highDb = g
        }
    }
}

private struct EQGeometry {
    let size: CGSize
    let pad: CGFloat   // keeps the handles at the ends fully visible
    func x(_ f: Double) -> CGFloat { pad + (size.width - 2 * pad) * log(f / 20) / log(1000) }
    func f(_ x: CGFloat) -> Double { 20 * pow(1000, Double((x - pad) / (size.width - 2 * pad))) }
    func y(_ db: Double) -> CGFloat { size.height / 2 - db / 18 * size.height / 2 }
    func db(_ y: CGFloat) -> Double { Double((size.height / 2 - y) / (size.height / 2)) * 18 }

    func handle(_ b: Band, _ s: ChannelSettings) -> CGPoint {
        let f = b.freq(s)
        let g = b.gain(s) ?? max(-18, s.eqResponse(at: f))
        return CGPoint(x: x(f), y: y(g))
    }
}

struct EQEditor: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let channel: Int
    @State private var selected = Band.mid
    @State private var dragging: Band?
    @State private var grabOffset = CGSize.zero
    @FocusState private var focused: Bool

    var body: some View {
        let s = app.session.channels[channel]
        VStack(alignment: .leading, spacing: 10 * k) {
            HStack {
                Text("Drag the points to shape the curve. The high-pass is off at the far left; drag it right to roll off lows.")
                    .uiFont(13).foregroundStyle(Theme.secondary)
                Spacer()
                ResetButton(title: "Reset to flat", enabled: s.eqActive) { app.session.channels[channel].flattenEQ() }
            }
            GeometryReader { geo in
                let g = EQGeometry(size: geo.size, pad: 14 * k)
                Canvas { ctx, size in draw(ctx, g, s) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(g))
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                        nudge(press.key); return .handled
                    }
            }
            .background(RoundedRectangle(cornerRadius: 8 * k).fill(Theme.well))
            .clipShape(RoundedRectangle(cornerRadius: 8 * k))
            .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(focused ? Color.white.opacity(0.5) : Color.clear))
            .accessibilityElement()
            .accessibilityLabel("EQ curve, \(selected.name) selected")
            .accessibilityValue(info(s))
            .accessibilityAdjustableAction { dir in
                var c = app.session.channels[channel]
                selected.set(&c, freq: selected.freq(c), gain: (selected.gain(c) ?? 0) + (dir == .increment ? 0.5 : -0.5))
                app.session.channels[channel] = c
            }

            HStack(spacing: 16 * k) {
                HStack(spacing: 6 * k) {
                    ForEach(Band.allCases) { b in
                        Button { selected = b } label: {
                            Text(b.name).uiFont(12, .semibold)
                                .padding(.horizontal, 10 * k).frame(height: 28 * k)
                                .foregroundStyle(selected == b ? Color.black : Theme.text)
                                .background(Capsule().fill(selected == b ? b.color : Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(info(s)).uiFont(14, mono: true)
                Spacer()
                if selected == .mid {
                    Text("Width").font(.system(size: 13 * k)).foregroundStyle(Theme.secondary)
                    stepButton("minus", "Narrower") { setQ(s.midQ + 0.2) }
                    Text(String(format: "Q %.1f", s.midQ)).uiFont(13, mono: true).frame(width: 48 * k)
                    stepButton("plus", "Wider") { setQ(s.midQ - 0.2) }
                }
            }
            .frame(minHeight: 36 * k)
        }
        .padding(16 * k)
        .background(RoundedRectangle(cornerRadius: 12 * k).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12 * k).stroke(Theme.border))
    }


    private func info(_ s: ChannelSettings) -> String {
        let f = hzLabel(selected.freq(s))
        if let g = selected.gain(s) { return "\(selected.name) · \(f) · \(signedDb(g))" }
        return s.hpfActive ? "\(selected.name) · \(f) · 12 dB/octave" : "\(selected.name) · off"
    }

    private func setQ(_ q: Double) {
        app.session.channels[channel].midQ = (min(5, max(0.3, q)) * 10).rounded() / 10
    }

    private func stepButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 34 * k, height: 34 * k)
                .background(RoundedRectangle(cornerRadius: 8 * k).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8 * k).stroke(Theme.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func nudge(_ key: KeyEquivalent) {
        var c = app.session.channels[channel]
        var f = selected.freq(c), gain = selected.gain(c) ?? 0
        switch key {
        case .leftArrow: f /= 1.06
        case .rightArrow: f *= 1.06
        case .upArrow: gain += 0.5
        default: gain -= 0.5
        }
        selected.set(&c, freq: f, gain: gain)
        app.session.channels[channel] = c
    }

    private func dragGesture(_ g: EQGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let s = app.session.channels[channel]
                if dragging == nil {
                    let near = Band.allCases.map { ($0, g.handle($0, s)) }
                        .min { hypot($0.1.x - v.startLocation.x, $0.1.y - v.startLocation.y)
                             < hypot($1.1.x - v.startLocation.x, $1.1.y - v.startLocation.y) }!
                    guard hypot(near.1.x - v.startLocation.x, near.1.y - v.startLocation.y) < 40 * k else { return }
                    dragging = near.0
                    selected = near.0
                    grabOffset = CGSize(width: near.1.x - v.startLocation.x, height: near.1.y - v.startLocation.y)
                    focused = true
                }
                guard let b = dragging else { return }
                var c = s
                b.set(&c, freq: g.f(v.location.x + grabOffset.width), gain: g.db(v.location.y + grabOffset.height))
                app.session.channels[channel] = c
            }
            .onEnded { _ in dragging = nil }
    }

    private func draw(_ ctx: GraphicsContext, _ g: EQGeometry, _ s: ChannelSettings) {
        let w = g.size.width, h = g.size.height
        for f in [100.0, 1000, 10000] {
            ctx.stroke(Path { $0.move(to: CGPoint(x: g.x(f), y: 0)); $0.addLine(to: CGPoint(x: g.x(f), y: h)) },
                       with: .color(.white.opacity(0.10)))
        }
        for db in [-12.0, -6, 6, 12] {
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: g.y(db))); $0.addLine(to: CGPoint(x: w, y: g.y(db))) },
                       with: .color(.white.opacity(0.07)))
        }
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: h / 2)); $0.addLine(to: CGPoint(x: w, y: h / 2)) },
                   with: .color(.white.opacity(0.22)))
        let labels: [(String, Double)] = [("20 Hz", 20), ("100", 100), ("1k", 1000), ("10k", 10000), ("20 kHz", 20000)]
        for (t, f) in labels {
            let x = min(w - 24, max(24, g.x(f)))
            ctx.draw(Text(t).font(.system(size: 11 * k)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: x, y: h - 10))
        }
        ctx.draw(Text("+18 dB").font(.system(size: 11 * k)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: 26, y: 12))
        ctx.draw(Text("−18 dB").font(.system(size: 11 * k)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: 26, y: h - 26))

        var curve = Path()
        let n = max(2, Int(w / 3))
        for i in 0...n {
            let x = w * CGFloat(i) / CGFloat(n)
            let pt = CGPoint(x: x, y: min(h - 1, max(1, g.y(s.eqResponse(at: g.f(x))))))
            if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: w, y: h / 2)); fill.addLine(to: CGPoint(x: 0, y: h / 2)); fill.closeSubpath()
        ctx.fill(fill, with: .color(.white.opacity(0.07)))
        ctx.stroke(curve, with: .color(.white), lineWidth: 2.5)

        for b in Band.allCases {
            var p = g.handle(b, s)
            p.y = min(h - 2, max(2, p.y))
            let r: CGFloat = (b == selected ? 11 : 8) * k
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(b.isOn(s) ? b.color : Color(hex: 0x55585E)))
            ctx.stroke(dot, with: .color(b == selected ? .white : Theme.well), lineWidth: 2)
        }
    }
}

// MARK: - Compressor

private struct CompGeometry {
    let side: CGFloat
    let pad: CGFloat   // keeps the handles at the edges fully visible
    private var span: CGFloat { side - 2 * pad }
    func x(_ input: Double) -> CGFloat { pad + (input + 60) / 60 * span }
    func input(_ x: CGFloat) -> Double { Double((x - pad) / span) * 60 - 60 }
    func y(_ out: Double) -> CGFloat { pad + (12 - out) / 72 * span }
    func out(_ y: CGFloat) -> Double { 12 - Double((y - pad) / span) * 72 }
}

struct CompEditor: View {
    @Environment(\.uiScale) private var k
    @Environment(AppState.self) private var app
    let channel: Int
    @State private var dragging: String?
    @State private var grabOffset = CGSize.zero

    var body: some View {
        let s = app.session.channels[channel]
        HStack(alignment: .top, spacing: 16 * k) {
            VStack(alignment: .leading, spacing: 10 * k) {
                Text("Drag the knee to set threshold (left/right) and makeup gain (up/down). Drag the right-hand point to set the ratio. The green dot is the live input.")
                    .uiFont(13).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    let g = CompGeometry(side: side, pad: 16 * k)
                    Canvas { ctx, _ in draw(ctx, g, s) }
                        .frame(width: side, height: side)
                        .background(Theme.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8 * k))
                        .contentShape(Rectangle())
                        .gesture(dragGesture(g))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel("Compressor curve")
                        .accessibilityValue(summary(s))
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 18 * k) {
                HStack {
                    Text("Compressor").uiFont(15, .semibold)
                    Spacer()
                    ResetButton(title: "Reset to linear", enabled: s.compActive) { app.session.channels[channel].linearComp() }
                }
                Grid(alignment: .leading, horizontalSpacing: 12 * k, verticalSpacing: 10 * k) {
                    row("Threshold", String(format: "%.1f dB", s.thresholdDb))
                    row("Ratio", s.ratio >= 20 ? "20:1 (limiting)" : String(format: "%.1f:1", s.ratio))
                    row("Makeup gain", signedDb(s.makeupDb))
                }
                VStack(alignment: .leading, spacing: 6 * k) {
                    let gr = app.meters.gainReduction[channel]
                    HStack {
                        Text("Gain reduction").foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(gr > 0.05 ? String(format: "−%.1f dB", gr) : "0.0 dB").monospacedDigit()
                    }
                    .uiFont(13)
                    GeometryReader { g in
                        ZStack(alignment: .trailing) {
                            Capsule().fill(Color(hex: 0x1A1B1E))
                            Capsule().fill(Theme.gr).frame(width: g.size.width * min(1, gr / 20))
                        }
                    }
                    .frame(height: 10 * k)
                    .accessibilityHidden(true)
                }
                logSlider("Attack", value: \.attackMs, low: 0.2, high: 100) {
                    $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0)
                }
                logSlider("Release", value: \.releaseMs, low: 20, high: 1000) { String(format: "%.0f ms", $0) }
                Spacer()
            }
            .frame(width: 300 * k)
        }
        .padding(16 * k)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12 * k).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12 * k).stroke(Theme.border))
    }

    private func summary(_ s: ChannelSettings) -> String {
        String(format: "threshold %.1f dB, ratio %.1f to 1, makeup %.1f dB", s.thresholdDb, s.ratio, s.makeupDb)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .uiFont(14)
    }

    private func logSlider(_ label: String, value kp: WritableKeyPath<ChannelSettings, Double>,
                           low: Double, high: Double, format: @escaping (Double) -> String) -> some View {
        let v = app.session.channels[channel][keyPath: kp]
        let t = Binding(
            get: { log(app.session.channels[channel][keyPath: kp] / low) / log(high / low) },
            set: { app.session.channels[channel][keyPath: kp] = low * pow(high / low, $0) })
        return VStack(alignment: .leading, spacing: 4 * k) {
            HStack {
                Text(label).foregroundStyle(Theme.secondary)
                Spacer()
                Text(format(v)).monospacedDigit()
            }
            .uiFont(13)
            Slider(value: t, in: 0...1).tint(.white).accessibilityLabel(label).accessibilityValue(format(v))
        }
    }

    private func handles(_ g: CompGeometry, _ s: ChannelSettings) -> [(String, CGPoint)] {
        return [("knee", CGPoint(x: g.x(s.thresholdDb), y: g.y(s.thresholdDb + s.makeupDb))),
                ("end", CGPoint(x: g.x(0), y: g.y(s.compOutput(forInput: 0))))]
    }

    private func dragGesture(_ g: CompGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let s = app.session.channels[channel]
                if dragging == nil {
                    guard let near = handles(g, s).min(by: {
                        hypot($0.1.x - v.startLocation.x, $0.1.y - v.startLocation.y)
                            < hypot($1.1.x - v.startLocation.x, $1.1.y - v.startLocation.y) }),
                          hypot(near.1.x - v.startLocation.x, near.1.y - v.startLocation.y) < 40 * k else { return }
                    dragging = near.0
                    grabOffset = CGSize(width: near.1.x - v.startLocation.x, height: near.1.y - v.startLocation.y)
                }
                var c = s
                let input = g.input(v.location.x + grabOffset.width)
                let output = g.out(v.location.y + grabOffset.height)
                if dragging == "knee" {
                    c.thresholdDb = min(-2, max(-50, input))
                    c.makeupDb = min(20, max(0, output - c.thresholdDb))
                } else {
                    let rise = output - c.makeupDb - c.thresholdDb
                    c.ratio = rise <= 0.5 ? 20 : min(20, max(1, -c.thresholdDb / rise))
                }
                app.session.channels[channel] = c
            }
            .onEnded { _ in dragging = nil }
    }

    private func draw(_ ctx: GraphicsContext, _ g: CompGeometry, _ s: ChannelSettings) {
        let side = g.side
        for v in [-48.0, -36, -24, -12] {
            ctx.stroke(Path { $0.move(to: CGPoint(x: g.x(v), y: 0)); $0.addLine(to: CGPoint(x: g.x(v), y: side)) },
                       with: .color(.white.opacity(0.07)))
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: g.y(v))); $0.addLine(to: CGPoint(x: side, y: g.y(v))) },
                       with: .color(.white.opacity(0.07)))
        }
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: g.y(0))); $0.addLine(to: CGPoint(x: side, y: g.y(0))) },
                   with: .color(.white.opacity(0.18)))
        ctx.stroke(Path { $0.move(to: CGPoint(x: g.x(-60), y: g.y(-60))); $0.addLine(to: CGPoint(x: g.x(0), y: g.y(0))) },
                   with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))

        var curve = Path()
        curve.move(to: CGPoint(x: g.x(-60), y: g.y(s.compOutput(forInput: -60))))
        curve.addLine(to: CGPoint(x: g.x(s.thresholdDb), y: g.y(s.compOutput(forInput: s.thresholdDb))))
        curve.addLine(to: CGPoint(x: g.x(0), y: g.y(s.compOutput(forInput: 0))))
        ctx.stroke(curve, with: .color(.white), lineWidth: 3)

        let input = min(0, max(-60, app.meters.input[channel]))
        let live = CGPoint(x: g.x(input), y: max(0, g.y(s.compOutput(forInput: input))))
        ctx.fill(Path(ellipseIn: CGRect(x: live.x - 6 * k, y: live.y - 6 * k, width: 12 * k, height: 12 * k)), with: .color(Theme.good))

        for (_, p) in handles(g, s) {
            let dot = Path(ellipseIn: CGRect(x: p.x - 11 * k, y: p.y - 11 * k, width: 22 * k, height: 22 * k))
            ctx.fill(dot, with: .color(.white))
            ctx.stroke(dot, with: .color(Theme.well), lineWidth: 2)
        }
        ctx.draw(Text("−60 dB in").font(.system(size: 11 * k)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: 34, y: side - 10))
        ctx.draw(Text("0 dB in").font(.system(size: 11 * k)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: side - 26, y: side - 10))
        ctx.draw(Text("+12 dB out").font(.system(size: 11 * k)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: 36, y: 12))
    }
}

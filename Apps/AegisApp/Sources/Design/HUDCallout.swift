import SwiftUI

/// A reading pinned to what it describes (the design system's HudCallout): an anchor dot with a ring (it pings while
/// `pulse`), a hairline leader to the elbow, and the label standing on the elbow, underlined, with a code, an optional
/// lead (a figure, art), a title, a line of text and actions. No box: it's drawn into the scene. Positions are in the
/// parent's coordinates, top left at the origin.
struct HUDCallout<Lead: View, Actions: View>: View {
    enum Side {
        case left, right
    }

    let anchor: CGPoint
    let elbow: CGPoint
    var side = Side.right
    var tone = HUDToken.primary
    var pulse = false
    var still = false
    var code: String?
    var title: String?
    var text: String?
    var width: CGFloat = 440
    @ViewBuilder var lead: Lead
    @ViewBuilder var actions: Actions
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let colour = theme.color(tone)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: elbow)
            }
            .stroke(colour.opacity(0.7), lineWidth: 1)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !pulse || still)) { context in
                let ping = pulse && !still ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8 : -1
                ZStack {
                    Circle().stroke(colour, lineWidth: 1).frame(width: 14, height: 14).opacity(0.45)
                    if ping >= 0 {
                        let grown = HUDMotion.Curve(0.2, 0.7, 0.2, 1)(ping)
                        Circle().stroke(colour, lineWidth: 1).frame(width: 14, height: 14)
                            .scaleEffect(0.5 + 1.7 * grown).opacity(0.8 * (1 - grown))
                    }
                    Circle().fill(colour).frame(width: 5, height: 5).shadow(color: colour, radius: 2)
                }
                .position(anchor)
            }
            // The label hugs its content up to `width`, standing on the elbow on its side.
            Color.clear.frame(width: 0, height: 0)
                .overlay(alignment: side == .right ? .bottomLeading : .bottomTrailing) {
                    label(colour).frame(width: width, alignment: side == .right ? .bottomLeading : .bottomTrailing)
                }
                .position(elbow)
        }
    }

    private func label(_ colour: Color) -> some View {
        VStack(alignment: side == .right ? .leading : .trailing, spacing: 2) {
            if let code {
                Text(code).hudCaps(10, tracking: 0.2).foregroundStyle(colour)
            }
            lead
            if let title {
                Text(title).font(.custom(HUDType.body.fontName, size: 14))
                    .foregroundStyle(HUD.ink)
            }
            if let text {
                Text(text).font(HUDFace.mono(12)).foregroundStyle(HUD.inkMuted)
            }
            HStack(spacing: 14) { actions }.padding(.top, 4)
        }
        .multilineTextAlignment(side == .right ? .leading : .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .padding(EdgeInsets(top: 0, leading: 2, bottom: 7, trailing: 2))
        .overlay(alignment: .bottom) { Rectangle().fill(colour.opacity(0.7)).frame(height: 1) }
        .overlay(alignment: side == .right ? .bottomTrailing : .bottomLeading) {
            Rectangle().fill(colour).frame(width: 3, height: 3).offset(x: side == .right ? 2 : -2, y: 2)
        }
    }
}

extension HUDCallout where Lead == EmptyView {
    init(
        anchor: CGPoint, elbow: CGPoint, side: Side = .right, tone: HUDToken = .primary, pulse: Bool = false, still: Bool = false,
        code: String?, title: String?, text: String?, width: CGFloat = 440, @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            anchor: anchor, elbow: elbow, side: side, tone: tone, pulse: pulse, still: still, code: code, title: title, text: text,
            width: width, lead: { EmptyView() }, actions: actions
        )
    }
}

/// A callout's figure: the value in display numerals, glowing, with its unit.
struct HUDCalloutValue: View {
    let value: String
    let unit: String
    var tone = HUDToken.primary
    @Environment(\.hudTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(HUDFace.hero(30)).tracking(0.6).monospacedDigit().foregroundStyle(theme.color(tone))
                .shadow(color: theme.color(tone).opacity(0.55), radius: 7)
            Text(unit).hudCaps(11, tracking: 0.16).foregroundStyle(HUD.inkMuted)
        }
    }
}

/// An action that lives in the scene (the design system's HudLink): an arrow and a label, underlined on hover, no plate.
struct HUDLinkStyle: ButtonStyle {
    var tone = HUDToken.primary

    func makeBody(configuration: Configuration) -> some View {
        HUDLinkFace(configuration: configuration, tone: tone)
    }
}

private struct HUDLinkFace: View {
    let configuration: ButtonStyleConfiguration
    let tone: HUDToken
    @State private var hovering = false
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let colour = theme.color(tone)
        HStack(spacing: 6) {
            Text("›").font(HUDFace.mono(14))
            configuration.label.hudCaps(11, tracking: 0.18)
        }
        .foregroundStyle(colour)
        .padding(.vertical, 1)
        .overlay(alignment: .bottom) { Rectangle().fill(colour).frame(height: 1).opacity(hovering ? 1 : 0) }
        .shadow(color: hovering ? colour : .clear, radius: 5)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.7 : 1)
        .onHover { hovering = $0 }
    }
}

/// Readings wrapped round a centre (the design system's DataOrbit): arcs filled to a value, their label set along the
/// curve (below it on the lower half, reading left to right), and tick rings that turn slowly. Angles are degrees
/// clockwise from the top.
struct HUDOrbit: View {
    struct Arc {
        let radius: CGFloat
        let from: Double
        let to: Double
        let value: Double
        var tone = HUDToken.primary
        var width: CGFloat = 3
        var label: String?
    }

    struct Ring {
        let radius: CGFloat
        var ticks = 0
        var length: CGFloat = 4
        var major = 0
        var tone = HUDToken.frame
        /// Degrees a second; 0 holds it.
        var spin = 0.0
        var from = 0.0
        var to = 360.0
        var dashed = false
    }

    let size: CGFloat
    var arcs: [Arc] = []
    var rings: [Ring] = []
    var still = false
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let spins = !still && rings.contains { $0.spin != 0 }
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !spins)) { context in
            Canvas { canvas, _ in
                let seconds = spins ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 0
                for ring in rings {
                    draw(ring, turned: ring.spin * seconds, in: &canvas)
                }
                for arc in arcs {
                    draw(arc, in: &canvas)
                }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: size / 2 + sin(radians) * radius, y: size / 2 - cos(radians) * radius)
    }

    private func path(_ from: Double, _ to: Double, _ radius: CGFloat) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: size / 2, y: size / 2), radius: radius,
                startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false
            )
        }
    }

    private func draw(_ ring: Ring, turned: Double, in canvas: inout GraphicsContext) {
        let colour = theme.color(ring.tone).opacity(ring.tone == .frame ? 1 : 0.55)
        let guide = ring.to - ring.from >= 360 ? Path(ellipseIn: CGRect(
            x: size / 2 - ring.radius, y: size / 2 - ring.radius, width: ring.radius * 2, height: ring.radius * 2
        )) : path(ring.from, ring.to, ring.radius)
        canvas.stroke(guide, with: .color(colour), style: StrokeStyle(lineWidth: 1, dash: ring.dashed ? [2, 5] : []))
        guard ring.ticks > 0 else { return }
        var ticks = Path()
        for index in 0 ..< ring.ticks {
            let degrees = ring.from + Double(index) * (ring.to - ring.from) / Double(ring.ticks) + turned
            let long = ring.major > 0 && index.isMultiple(of: ring.major)
            ticks.move(to: point(degrees, ring.radius))
            ticks.addLine(to: point(degrees, ring.radius + ring.length * (long ? 2 : 1)))
        }
        canvas.stroke(ticks, with: .color(colour), lineWidth: 1)
    }

    private func draw(_ arc: Arc, in canvas: inout GraphicsContext) {
        let colour = theme.color(arc.tone)
        canvas.stroke(path(arc.from, arc.to, arc.radius), with: .color(colour.opacity(0.16)), lineWidth: arc.width)
        let value = min(max(arc.value, 0), 1)
        if value > 0 {
            var glow = canvas
            glow.addFilter(.shadow(color: colour.opacity(0.7), radius: 4))
            glow.stroke(path(arc.from, arc.from + (arc.to - arc.from) * value, arc.radius), with: .color(colour), lineWidth: arc.width)
        }
        guard let label = arc.label else { return }
        // The label runs along the curve, centred on the arc, outside it; upright on both halves.
        let middle = (arc.from + arc.to) / 2,
            turned = (middle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let bottom = turned > 90 && turned < 270
        let radius = arc.radius + arc.width + (bottom ? 12 : 6)
        let glyphs = label.uppercased()
            .map { canvas.resolve(Text(String($0)).font(.custom(HUDType.label.fontName, size: 10)).foregroundStyle(colour)) }
        let advances = glyphs.map { $0.measure(in: CGSize(width: 100, height: 100)).width + 2.2 }
        let total = advances.reduce(0, +)
        var along = -total / 2
        for (glyph, advance) in zip(glyphs, advances) {
            let degrees = middle + (bottom ? -1 : 1) * Double((along + advance / 2) / radius) * 180 / .pi
            var layer = canvas
            layer.translateBy(x: point(degrees, radius).x, y: point(degrees, radius).y)
            layer.rotate(by: .degrees(bottom ? degrees - 180 : degrees))
            layer.draw(glyph, at: .zero, anchor: UnitPoint(x: 0.5, y: bottom ? 0.25 : 0.75))
            along += advance
        }
    }
}

/// Someone on an orbit (the design system's DataOrbit satellite): a diamond on the ring with their name, how long, and a
/// note beside it, on the side it sits.
struct HUDSatellite: View {
    let label: String
    var value: String?
    var note: String?
    var tone = HUDToken.ink
    var pulse = false
    var left = false
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let colour = theme.color(tone)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.custom(HUDType.body.fontName, size: 13)).foregroundStyle(colour)
            if let value {
                Text(value).font(HUDFace.mono(12)).foregroundStyle(colour.opacity(0.85))
            }
            if let note {
                Text(note).font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
            }
        }
        .environment(\.layoutDirection, left ? .rightToLeft : .leftToRight)
        .lineLimit(1)
        .fixedSize()
    }

    /// The diamond.
    struct Dot: View {
        var tone = HUDToken.ink
        var pulse = false
        var still = false
        @Environment(\.hudTheme) private var theme

        var body: some View {
            let colour = theme.color(tone)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !pulse || still)) { context in
                Rectangle().fill(colour.opacity(0.35))
                    .overlay(Rectangle().strokeBorder(colour, lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .shadow(color: colour.opacity(0.6), radius: 4)
                    .opacity(pulse && !still ? HUDMotion.breathe(context.date.timeIntervalSinceReferenceDate * 3.2 / 1.4) : 1)
            }
        }
    }
}

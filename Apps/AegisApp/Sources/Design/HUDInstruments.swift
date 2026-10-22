import SwiftUI

/// A labelled number: label caps over a mono value with an optional unit. A primary value is live and glows. The
/// value scrambles and settles as it arrives.
struct HUDReadout: View {
    let label: String
    let value: String
    var unit: String?
    var tone = HUD.ink

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space1) {
            Text(label).hudType(.label).foregroundStyle(HUD.inkMuted).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: HUD.space1) {
                HUDScramble(text: value, glow: tone == HUD.primary).hudType(.readout).monospacedDigit().foregroundStyle(tone)
                if let unit {
                    Text(unit).hudType(.data).foregroundStyle(HUD.inkMuted)
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The HUD's progress bar: tall thin bars inside an open bracket frame, lit bars glowing in the tone, unlit bars the
/// same tone dimmed. Large is for the one loading bar on a screen, its label and value set above it in Xirod. The lit
/// bars light one by one as it arrives.
struct HUDMeter: View {
    enum Size {
        case small, medium, large
    }

    let label: String
    let value: Double
    var display: String?
    var size = Size.medium
    var tone = HUD.primary

    var body: some View {
        let fraction = min(max(value, 0), 1)
        let shown = display ?? "\(Int((fraction * 100).rounded()))%"
        VStack(alignment: size == .large ? .center : .leading, spacing: size == .large ? HUD.space2 : HUD.space1) {
            if size == .large {
                Text(label + " " + shown).hudType(.title).foregroundStyle(HUD.frame).hudGlow()
            } else {
                HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                    Text(label).hudType(.label).foregroundStyle(HUD.inkMuted)
                    Spacer(minLength: HUD.space2)
                    Text(shown).hudType(.data).monospacedDigit().foregroundStyle(HUD.ink)
                }
                .lineLimit(1)
            }
            HUDSegments(value: fraction, count: size == .small ? 40 : size == .large ? 90 : 60, tone: tone)
                .frame(height: size == .small ? 6 : size == .large ? 22 : 10)
                .padding(.vertical, size == .large ? 6 : 3)
                .padding(.horizontal, size == .large ? 10 : 5)
                .overlay(HUDMeterBrackets().stroke(HUD.frame, lineWidth: HUD.strokeHair))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(shown)
    }
}

private struct HUDSegments: View {
    let value: Double
    let count: Int
    let tone: HUDColor
    @Environment(\.hudTheme) private var theme

    var body: some View {
        HUDBuildClock(until: 0.4 + 0.009 * Double(count)) { time in
            Canvas { context, size in
                let color = theme.color(tone.token)
                let lit = Int((value * Double(count)).rounded())
                let step = (size.width - 1.5) / CGFloat(max(count - 1, 1))
                var on = Path()
                var off = Path()
                for index in 0 ..< count {
                    let bar = CGRect(x: CGFloat(index) * step, y: 0, width: 1.5, height: size.height)
                    if index < lit {
                        on.addRect(bar)
                    } else {
                        off.addRect(bar)
                    }
                }
                context.fill(off, with: .color(color.opacity(0.25)))
                if HUDMotion.progress(time, 0.26 + 0.009 * Double(lit), 0.14) < 1 {
                    // Arriving, each lit bar brightens from the unlit level 9 ms after the one before; the glow waits
                    // until they're all lit, so nothing glows while it moves.
                    for index in 0 ..< lit {
                        let shown = HUDMotion.standard(HUDMotion.progress(time, 0.26 + 0.009 * Double(index), 0.14))
                        let bar = CGRect(x: CGFloat(index) * step, y: 0, width: 1.5, height: size.height)
                        context.fill(Path(bar), with: .color(color.opacity(0.25 + 0.75 * shown)))
                    }
                } else {
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: color, radius: 2))
                        layer.fill(on, with: .color(color))
                    }
                }
            }
        }
    }
}

/// An open bracket at each end, its arms reaching a little way in.
private struct HUDMeterBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let arm = rect.width * 0.22
        var path = Path()
        path.addLines([
            CGPoint(x: box.minX + arm, y: box.minY), CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX + arm, y: box.maxY),
        ])
        path.addLines([
            CGPoint(x: box.maxX - arm, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.maxX - arm, y: box.maxY),
        ])
        return path
    }
}

/// The progress bar typed in characters, `[||||||····] 79%`: the text-mode twin of the meter.
struct HUDCharMeter: View {
    let value: Double
    var width = 24
    var display: String?
    var tone = HUD.primary

    var body: some View {
        let fraction = min(max(value, 0), 1)
        let lit = Int((fraction * Double(width)).rounded())
        (Text("[").foregroundStyle(HUD.frame)
            + Text(String(repeating: "|", count: lit)).tracking(-1.4).foregroundStyle(tone)
            + Text(String(repeating: "|", count: width - lit)).tracking(-1.4).foregroundStyle(tone.opacity(0.3))
            + Text("]").foregroundStyle(HUD.frame)
            + Text(" " + (display ?? "\(Int((fraction * 100).rounded()))%")).foregroundStyle(HUD.ink))
            .hudType(.term)
            .lineLimit(1)
            .accessibilityLabel(display ?? "\(Int((fraction * 100).rounded())) percent")
    }
}

/// The only round instrument: a 60-tick dial, cross-hair marks, a butt-capped value arc from 12 o'clock and the value
/// in Xirod at the centre. Arriving, its guide draws round, the ticks light in turn, the marks flicker on, the arc
/// eases to its value and the figure scrambles and settles.
struct HUDRing: View {
    let value: Double
    let label: String
    var display: String?
    var tone = HUD.primary
    var size: CGFloat = 160
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let fraction = min(max(value, 0), 1)
        ZStack {
            HUDBuildClock(until: 1.12) { time in
                Canvas { context, _ in
                    let marks = HUDMotion.flicker(HUDMotion.progress(time, 0.3, 0.26))
                    let centre = size / 2
                    let point = { (radius: CGFloat, angle: Double) in
                        CGPoint(x: centre + sin(angle) * radius, y: centre - cos(angle) * radius)
                    }
                    var guide = Path()
                    guide.addArc(
                        center: CGPoint(x: centre, y: centre), radius: centre - 4, startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * HUDMotion.standard(HUDMotion.progress(time, 0, 0.52))), clockwise: false
                    )
                    context.stroke(guide, with: .color(theme.color(.line)))
                    for tick in 0 ..< 60 {
                        let angle = Double(tick) / 60 * 2 * .pi
                        let major = tick.isMultiple(of: 5)
                        var mark = Path()
                        mark.move(to: point(centre - 10 - (major ? 6 : 3), angle))
                        mark.addLine(to: point(centre - 10, angle))
                        let shown = HUDMotion.progress(time, 0.12 + 0.007 * Double(tick), 0.12)
                        context.stroke(mark, with: .color(theme.color(major ? .inkMuted : .line).opacity(shown)))
                    }
                    var cross = Path()
                    for (from, to) in [
                        ((centre, 0.0), (centre, 8.0)),
                        ((centre, size - 8), (centre, size)),
                        ((0, centre), (8, centre)),
                        ((size - 8, centre), (size, centre)),
                    ] {
                        cross.move(to: CGPoint(x: from.0, y: from.1))
                        cross.addLine(to: CGPoint(x: to.0, y: to.1))
                    }
                    context.stroke(cross, with: .color(theme.color(.frame).opacity(marks)), lineWidth: 2)
                    let arc = centre - 26
                    context.stroke(
                        Path(ellipseIn: CGRect(x: centre - arc, y: centre - arc, width: arc * 2, height: arc * 2)),
                        with: .color(theme.color(.primarySoft).opacity(marks)),
                        lineWidth: 2
                    )
                    let swept = HUDMotion.progress(time, 0.42, 0.7)
                    var value = Path()
                    value.addArc(
                        center: CGPoint(x: centre, y: centre),
                        radius: arc,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * fraction * HUDMotion.standard(swept)),
                        clockwise: false
                    )
                    // The arc glows once it has eased to its value, not while it moves.
                    context.drawLayer { layer in
                        if swept >= 1 {
                            layer.addFilter(.shadow(color: theme.color(tone.token), radius: 2))
                        }
                        layer.stroke(value, with: .color(theme.color(tone.token)), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    }
                    let inner = centre - 40
                    context.stroke(
                        Path(ellipseIn: CGRect(x: centre - inner, y: centre - inner, width: inner * 2, height: inner * 2)),
                        with: .color(theme.color(.line).opacity(marks)),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 4])
                    )
                }
            }
            VStack(spacing: 2) {
                HUDScramble(text: display ?? "\(Int((fraction * 100).rounded()))", delay: 0.4)
                    .font(.custom("Xirod-Regular", size: 22)).tracking(0.44).monospacedDigit().foregroundStyle(HUD.ink)
                Text(label).hudType(.label).foregroundStyle(HUD.inkMuted)
            }
            .lineLimit(1)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display ?? "\(Int((fraction * 100).rounded())) percent")
    }
}

/// The showpiece chart: the series as a field of particles, dense and bright where the signal is, scattering thin at
/// the edges and fading in and out at both ends, with a second series as a dotted accent trail; between dotted column
/// rails capped with nodes. Exact numbers go in `display` and `captions`, never on the field.
struct HUDParticleField: View {
    let label: String
    var display: String?
    let data: [Double]
    /// How wide the cloud is around each value, as a share of the height: one for all, or one per sample.
    var spread: [Double] = [0.09]
    var trail: [Double] = []
    var ticks: [String] = []
    var captions: [String] = []
    var columns = 20
    var height: CGFloat = 150
    @Environment(\.hudTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space4) {
                Text(label).hudType(.label).foregroundStyle(HUD.inkMuted)
                Spacer(minLength: HUD.space2)
                if let display {
                    Text(display).hudType(.data).foregroundStyle(HUD.ink)
                }
            }
            .lineLimit(1)
            Canvas { context, size in
                let pad: CGFloat = ticks.isEmpty ? 18 : 26
                drawRails(in: &context, size: size, pad: pad)
                guard !data.isEmpty else { return }
                let cloud = HUDParticles.cloud(
                    .init(data: data, spread: spread, trail: trail),
                    size: size,
                    count: Int(size.width * 2.6),
                    seed: 7,
                    pad: pad
                )
                HUDParticles.draw(cloud, in: &context, theme: theme, tone: .primary)
            }
            .frame(height: height)
            .hudArrive(.wipe(0.8), after: 0.26)
            if !captions.isEmpty {
                HStack(spacing: HUD.space8) {
                    ForEach(captions, id: \.self) { caption in
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Rectangle().fill(HUD.inkMuted).frame(width: 16, height: 1).rotationEffect(.degrees(-45)).frame(
                                width: 12,
                                height: 12
                            )
                            Text(caption).hudType(.data).foregroundStyle(HUD.ink)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(([display] + captions.map(Optional.some)).compactMap(\.self).joined(separator: ", "))
    }

    private func drawRails(in context: inout GraphicsContext, size: CGSize, pad: CGFloat) {
        var rails = Path()
        var nodes = Path()
        for column in 0 ..< columns {
            let px = pad + (columns == 1 ? 0.5 : CGFloat(column) / CGFloat(columns - 1)) * (size.width - 2 * pad)
            rails.move(to: CGPoint(x: px, y: pad / 2))
            rails.addLine(to: CGPoint(x: px, y: size.height - pad / 2))
            nodes.addEllipse(in: CGRect(x: px - 1.6, y: pad / 2 - 1.6, width: 3.2, height: 3.2))
            nodes.addEllipse(in: CGRect(x: px - 1.6, y: size.height - pad / 2 - 1.6, width: 3.2, height: 3.2))
            if column < ticks.count, !ticks[column].isEmpty {
                context.draw(
                    Text(ticks[column]).font(HUDType.data.font).foregroundStyle(theme.color(.inkMuted)),
                    at: CGPoint(x: px, y: size.height - 2), anchor: .bottom
                )
            }
        }
        context.stroke(rails, with: .color(theme.color(.line)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        context.fill(nodes, with: .color(theme.color(.inkMuted)))
    }
}

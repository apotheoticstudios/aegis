import SwiftUI

/// A small trend between dotted column rails capped with nodes: a line over a soft area with a square on every
/// sample and an accent mark over the peak, thin bars with the peak in ink, or a small particle cloud. No axes and
/// no legend; the latest value sits in text beside it. Arriving, bars grow from the baseline in turn, the line draws
/// on and the particles wipe in.
struct HUDSparkline: View {
    enum Variant {
        case line, bars, particles
    }

    let label: String
    let data: [Double]
    var display: String?
    var variant = Variant.line
    var tone = HUD.primary
    var columns = 9
    var height: CGFloat = 56
    @Environment(\.hudTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space1) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                Text(label).hudType(.label).foregroundStyle(HUD.inkMuted)
                Spacer(minLength: HUD.space2)
                Text(display ?? "").hudType(.data).monospacedDigit().foregroundStyle(HUD.ink)
            }
            .lineLimit(1)
            let chart = HUDBuildClock { time in
                Canvas { context, size in
                    HUDSparkDrawing(data: data, variant: variant, columns: columns, theme: theme, tone: tone.token, time: time).draw(
                        in: &context,
                        size: size
                    )
                }
            }
            .frame(height: height)
            if variant == .particles {
                chart.hudArrive(.wipe(0.8), after: 0.26)
            } else {
                chart
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display ?? "")
    }
}

private struct HUDSparkDrawing {
    let data: [Double]
    let variant: HUDSparkline.Variant
    let columns: Int
    let theme: HUDTheme
    let tone: HUDToken
    /// Seconds since the section arrived, nil once built.
    let time: Double?

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        var rails = Path()
        var nodes = Path()
        for column in 0 ..< columns {
            let px = 2 + CGFloat(column) / CGFloat(max(columns - 1, 1)) * (width - 4)
            rails.move(to: CGPoint(x: px, y: 2))
            rails.addLine(to: CGPoint(x: px, y: height - 2))
            nodes.addEllipse(in: CGRect(x: px - 1.1, y: 0.4, width: 2.2, height: 2.2))
        }
        context.stroke(rails, with: .color(theme.color(.line)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        context.fill(nodes, with: .color(theme.color(.inkMuted)))
        if !data.isEmpty {
            switch variant {
            case .bars: bars(in: &context, size: size)
            case .line: line(in: &context, size: size)
            case .particles: HUDParticles.draw(
                    HUDParticles.cloud(.init(data: data, spread: [0.14]), size: size, count: Int(width * 3), seed: 3, pad: 4),
                    in: &context, theme: theme, tone: tone
                )
            }
        }
        var base = Path()
        base.move(to: CGPoint(x: 0, y: height - 0.5))
        base.addLine(to: CGPoint(x: width, y: height - 0.5))
        context.stroke(base, with: .color(theme.color(.line)))
    }

    private func scaled(_ value: Double, _ height: CGFloat) -> CGFloat {
        let low = data.min() ?? 0
        let high = data.max() ?? 1
        let span = high > low ? high - low : max(high, 1)
        let base = high > low ? low : 0
        return 2 + (height - 4) * (1 - CGFloat((value - base) / span))
    }

    private func bars(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width / CGFloat(data.count)
        let peak = data.firstIndex(of: data.max() ?? 0)
        for (index, value) in data.enumerated() {
            // Each bar grows from the baseline 28 ms after the one before, and its cap lights once it's up.
            let grown = HUDMotion.standard(HUDMotion.progress(time, 0.26 + 0.028 * Double(index), 0.32))
            let capped = HUDMotion.progress(time, 0.46 + 0.028 * Double(index), 0.16)
            let top = size.height - (size.height - scaled(value, size.height)) * grown
            let centre = CGFloat(index) * width + width / 2
            let color = theme.color(index == peak ? .ink : tone)
            context.fill(Path(CGRect(x: centre - 0.75, y: top, width: 1.5, height: size.height - top)), with: .color(color))
            context.fill(Path(CGRect(x: centre - 1.5, y: top - 1, width: 3, height: 1.5)), with: .color(color.opacity(capped)))
        }
    }

    private func line(in context: inout GraphicsContext, size: CGSize) {
        let step = data.count > 1 ? (size.width - 6) / CGFloat(data.count - 1) : 0
        let points = data.enumerated().map { CGPoint(x: 2 + CGFloat($0.offset) * step, y: scaled($0.element, size.height)) }
        guard let first = points.first, let last = points.last else { return }
        // The line draws on, then its area, vertices and marks fade up.
        let marks = HUDMotion.progress(time, 0.76, 0.3)
        var area = Path()
        area.move(to: CGPoint(x: first.x, y: size.height))
        area.addLines(points)
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        context.fill(area, with: .color(theme.color(.primarySoft).opacity(marks)))
        var trace = Path()
        trace.addLines(points)
        trace = trace.trimmedPath(from: 0, to: HUDMotion.standard(HUDMotion.progress(time, 0.26, 0.7)))
        context.stroke(trace, with: .color(theme.color(tone)), style: StrokeStyle(lineWidth: 1.5, lineCap: .square, lineJoin: .miter))
        var vertices = Path()
        points.forEach { vertices.addRect(CGRect(x: $0.x - 1, y: $0.y - 1, width: 2, height: 2)) }
        context.fill(vertices, with: .color(theme.color(.ink).opacity(marks)))
        if let peak = data.firstIndex(of: data.max() ?? 0) {
            var mark = Path()
            mark.addLines([
                CGPoint(x: points[peak].x - 3, y: points[peak].y - 7), CGPoint(x: points[peak].x + 3, y: points[peak].y - 7),
                CGPoint(x: points[peak].x, y: points[peak].y - 3),
            ])
            context.fill(mark, with: .color(theme.color(.accent).opacity(marks)))
        }
        var now = Path()
        now.move(to: CGPoint(x: last.x, y: 2))
        now.addLine(to: CGPoint(x: last.x, y: size.height))
        context.stroke(now, with: .color(theme.color(.inkMuted)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        context.fill(Path(CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(theme.color(.ink).opacity(marks)))
    }
}

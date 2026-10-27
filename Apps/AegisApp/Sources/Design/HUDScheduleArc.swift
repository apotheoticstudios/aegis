import SwiftUI

/// Today's schedule as an open ring of hour ticks with each event as an arc (the design system's ScheduleArc): the
/// guide from `from` to `to` o'clock, the part already gone traced in `frame`, events past in `line`, under way in
/// `ok`, the next in `primary` with a glow and the rest in `accent`, and a NOW mark. `hidden` writes "Event" for
/// titles; `eventLabels` false leaves the events unlabelled.
struct HUDScheduleArc: View {
    struct Event: Equatable {
        let start: Date
        let end: Date
        let title: String
    }

    let events: [Event]
    let now: Date
    var size: CGFloat = 420
    var inset: CGFloat = 34
    var from = 6.0
    var to = 24.0
    var hourLabels = true
    var eventLabels = true
    var hidden = false
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Canvas { context, _ in draw(&context) }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }

    private var label: String {
        let next = events.first { minutes($0.start) > minutes(now) }
        return "Today: \(events.count) events" + (next.map { ", next at " + Self.clock($0.start) } ?? "")
    }

    private func draw(_ context: inout GraphicsContext) {
        let centre = size / 2, radius = centre - inset, current = minutes(now)
        func angle(_ minute: Double) -> Double {
            -150 + 300 * min(max((minute - from * 60) / ((to - from) * 60), 0), 1)
        }
        func point(_ degrees: Double, _ distance: CGFloat) -> CGPoint {
            let radians = (degrees - 90) * .pi / 180
            return CGPoint(x: centre + cos(radians) * distance, y: centre + sin(radians) * distance)
        }
        func arc(_ start: Double, _ end: Double, _ distance: CGFloat) -> Path {
            Path { path in
                path.addArc(
                    center: CGPoint(x: centre, y: centre), radius: distance,
                    startAngle: .degrees(angle(start) - 90), endAngle: .degrees(angle(end) - 90), clockwise: false
                )
            }
        }
        context.stroke(arc(from * 60, to * 60, radius), with: .color(theme.color(.line)), lineWidth: 1)
        context.stroke(
            arc(from * 60, min(current, to * 60), radius), with: .color(theme.color(.frame).opacity(0.6)), lineWidth: 1
        )
        for hour in stride(from: from, through: to, by: 1) {
            let degrees = angle(hour * 60), big = Int(hour).isMultiple(of: 3)
            let tick = Path { $0.move(to: point(degrees, radius + 4))
                $0.addLine(to: point(degrees, radius + (big ? 11 : 7)))
            }
            context.stroke(tick, with: .color(theme.color(big ? .inkMuted : .line)), lineWidth: 1)
            if big, hourLabels {
                let spot = point(degrees, radius + 22)
                context.draw(
                    text(String(format: "%02d", Int(hour) % 24), .inkMuted), at: CGPoint(x: spot.x, y: spot.y + 3),
                    anchor: UnitPoint(x: 0.5, y: 0.75)
                )
            }
        }
        drawEvents(&context, current: current, radius: radius, angle: angle, point: point, arc: arc)
        let mark = angle(current)
        context.stroke(
            Path { $0.move(to: point(mark, radius - 14))
                $0.addLine(to: point(mark, radius + 14))
            },
            with: .color(theme.color(.primary)), lineWidth: 1
        )
        let dot = point(mark, radius)
        context.fill(Path(CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(theme.color(.primary)))
    }

    // swiftlint:disable:next function_parameter_count
    private func drawEvents(
        _ context: inout GraphicsContext, current: Double, radius: CGFloat, angle: (Double) -> Double,
        point: (Double, CGFloat) -> CGPoint, arc: (Double, Double, CGFloat) -> Path
    ) {
        let next = events.firstIndex { minutes($0.start) > current }
        // Labels of events close together step inwards, up to three lanes.
        var lastAngle = -999.0, lane = 0
        let lanes = events.map { event -> Int in
            let start = minutes(event.start), end = max(minutes(event.end), start)
            guard end > current else { return 0 }
            let middle = angle((start + end) / 2)
            lane = middle - lastAngle < 34 ? (lane + 1) % 3 : 0
            lastAngle = middle
            return lane
        }
        for (index, event) in events.enumerated() {
            let start = minutes(event.start), end = max(minutes(event.end), start)
            let past = end <= current, isNext = index == next, under = !past && start <= current
            let (tone, width): (HUDToken, CGFloat) = past ? (.line, 3) : isNext ? (.primary, 4) : under ? (.ok, 4) : (.accent, 3)
            var layer = context
            if isNext {
                layer.addFilter(.shadow(color: theme.color(.primary), radius: 4))
            }
            layer.stroke(arc(start, end, radius), with: .color(theme.color(tone)), style: StrokeStyle(lineWidth: width, lineCap: .butt))
            guard eventLabels, !past else { continue }
            let middle = angle((start + end) / 2), spot = point(middle, radius - 18 - CGFloat(lanes[index]) * 15)
            context.draw(
                text(Self.clock(event.start) + " " + (hidden ? "Event" : event.title), isNext ? .ink : .inkMuted),
                at: CGPoint(x: spot.x, y: spot.y + 3), anchor: UnitPoint(x: middle > 0 ? 1 : 0, y: 0.75)
            )
        }
    }

    private func text(_ string: String, _ tone: HUDToken) -> Text {
        Text(string).font(HUDFace.mono(10)).foregroundStyle(theme.color(tone))
    }

    /// Minutes since the start of `now`'s day.
    private func minutes(_ date: Date) -> Double {
        date.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 60
    }

    /// "13:00": the design sets times on the 24-hour clock.
    static func clock(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }
}

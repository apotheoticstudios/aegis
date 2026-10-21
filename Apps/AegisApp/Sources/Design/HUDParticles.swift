import SwiftUI

/// The particle clouds behind the field and the small sparkline, generated from a seed so the same data always draws
/// the same picture (after the design system's makeField).
enum HUDParticles {
    struct Cloud {
        var core = Path()
        var mids = Path()
        var outer = Path()
        var trail = Path()
    }

    /// A series to draw: the values, how wide the cloud is around each (one for all, or one per value), and an
    /// optional second series for the trail.
    struct Series {
        var data: [Double]
        var spread = [0.09]
        var trail: [Double] = []
    }

    static func cloud(_ series: Series, size: CGSize, count: Int, seed: UInt32, pad: CGFloat) -> Cloud {
        let data = series.data
        let spread = series.spread
        let trail = series.trail
        var random = HUDRandom(seed: seed)
        let values = data + trail
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let span = high > low ? high - low : 1
        let base = high > low ? low : 0
        let inner = size.height - 2 * pad
        let place = { (value: Double) in pad + inner * CGFloat(1 - (value - base) / span) * 0.8 + inner * 0.1 }
        let middle = curve(data)
        let width = curve(spread.isEmpty ? [0.09] : spread)
        var cloud = Cloud()
        for _ in 0 ..< count {
            let along = random.next()
            let edge = min(along, 1 - along) / 0.12
            // The cloud fades out at both ends, and diffuses as it fades.
            if edge < 1, random.next() > edge * edge {
                continue
            }
            let scatter = edge < 1.6 ? 1 + (1.6 - edge) * 1.2 : 1
            let gauss = (-2 * log(random.next() + 1e-9)).squareRoot() * cos(2 * .pi * random.next())
            let px = pad + CGFloat(along) * (size.width - 2 * pad)
            let py = place(middle(along)) + CGFloat(gauss * max(0.01, width(along)) * scatter) * inner
            guard py >= pad / 2, py <= size.height - pad / 2 else { continue }
            let magnitude = abs(gauss)
            let diameter = magnitude < 0.55 ? 1.25 + random.next() * 0.6 : magnitude < 1.4 ? 0.8 + random.next() * 0.5 : 0.45 + random
                .next() * 0.35
            let dot = CGRect(x: px - diameter / 2, y: py - diameter / 2, width: diameter, height: diameter)
            if magnitude < 0.55 {
                cloud.core.addEllipse(in: dot)
            } else if magnitude < 1.4 {
                cloud.mids.addEllipse(in: dot)
            } else {
                cloud.outer.addEllipse(in: dot)
            }
        }
        cloud.trail = dots(along: trail, size: size, pad: pad, random: &random, place: place)
        return cloud
    }

    /// The second series as a dotted trail, thinning out at both ends.
    private static func dots(
        along trail: [Double], size: CGSize, pad: CGFloat, random: inout HUDRandom, place: (Double) -> CGFloat
    ) -> Path {
        var path = Path()
        guard !trail.isEmpty else { return path }
        let line = curve(trail)
        let steps = max(1, Int(((size.width - 2 * pad) / 7).rounded()))
        for step in 0 ... steps {
            let along = Double(step) / Double(steps)
            let edge = min(along, 1 - along) / 0.15
            if edge < 1, random.next() > edge {
                continue
            }
            let diameter = 1 + random.next() * 0.7
            let px = pad + CGFloat(along) * (size.width - 2 * pad) + CGFloat(random.next() - 0.5) * 2
            let py = place(line(along)) + CGFloat(random.next() - 0.5) * 5
            path.addEllipse(in: CGRect(x: px - diameter / 2, y: py - diameter / 2, width: diameter, height: diameter))
        }
        return path
    }

    static func draw(_ cloud: Cloud, in context: inout GraphicsContext, theme: HUDTheme, tone: HUDToken) {
        context.fill(cloud.outer, with: .color(theme.color(tone).opacity(0.45)))
        context.fill(cloud.trail, with: .color(theme.color(.accent)))
        context.fill(cloud.mids, with: .color(theme.color(tone)))
        context.fill(cloud.core, with: .color(theme.color(.ink)))
    }

    /// A Catmull-Rom curve through the values, sampled from 0 to 1.
    static func curve(_ values: [Double]) -> (Double) -> Double {
        { along in
            guard values.count > 1 else { return values.first ?? 0 }
            let position = along * Double(values.count - 1)
            let index = min(Int(position), values.count - 2)
            let fraction = position - Double(index)
            let before = values[max(index - 1, 0)]
            let start = values[index]
            let end = values[index + 1]
            let after = values[min(index + 2, values.count - 1)]
            return 0.5 * (2 * start + (end - before) * fraction + (2 * before - 5 * start + 4 * end - after) * fraction * fraction
                + (3 * start - before - 3 * end + after) * fraction * fraction * fraction)
        }
    }
}

/// A small, fast, seeded generator (mulberry32), so a picture drawn from data is the same every time.
struct HUDRandom {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed == 0 ? 1 : seed
    }

    /// 0 ..< 1.
    mutating func next() -> Double {
        state &+= 0x6D2B_79F5
        var mixed = (state ^ (state >> 15)) &* (1 | state)
        mixed = (mixed &+ ((mixed ^ (mixed >> 7)) &* (61 | mixed))) ^ mixed
        return Double(mixed ^ (mixed >> 14)) / 4_294_967_296
    }
}

import SwiftUI

/// The design system's motion (Motion.md): each time a screen shows in the open panel, it builds itself outside in,
/// in about 2 s, then holds still except for live things. Geometry glides on the ease curves;
/// text and flicker step. Every move is a pure function of time, so the build can be drawn at any moment.
enum HUDMotion {
    /// A CSS cubic-bezier easing from (0, 0) to (1, 1).
    struct Curve: Sendable {
        let x1, y1, x2, y2: Double

        init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
        }

        func callAsFunction(_ input: Double) -> Double {
            guard input > 0 else { return 0 }
            guard input < 1 else { return 1 }
            // The curve's x rises along it, so halve the interval until x lands on the input.
            var low = 0.0
            var high = 1.0
            for _ in 0 ..< 30 {
                let mid = (low + high) / 2
                if Self.bezier(x1, x2, mid) < input {
                    low = mid
                } else {
                    high = mid
                }
            }
            return Self.bezier(y1, y2, (low + high) / 2)
        }

        private static func bezier(_ first: Double, _ second: Double, _ along: Double) -> Double {
            let rest = 1 - along
            return 3 * rest * rest * along * first + 3 * rest * along * along * second + along * along * along
        }
    }

    /// The default: anything opening, drawing or resizing.
    static let standard = Curve(0.2, 0, 0, 1)
    /// Arrivals: fast start, long settle.
    static let enter = Curve(0.05, 0.7, 0.1, 1)
    /// Symmetric in-out for loops.
    static let ambient = Curve(0.45, 0, 0.55, 1)
    static let linear = Curve(0, 0, 1, 1)

    /// When each inset section arrives: 620 ms, then 110 ms apart down its column, so the side columns arrive in
    /// pairs, top to bottom.
    static func section(_ index: Int) -> Double {
        0.62 + 0.11 * Double(index)
    }

    /// When the shell's body and bottom strip arrive; anything there outside a section times itself from this.
    static let body = 0.68
    /// The build is over: only live things move after this, and anything new arrives at once.
    static let built = 3.0

    /// Siblings arriving together (rows, messages) `gap` apart; capped, so a late one never waits long.
    static func stagger(_ index: Int, _ gap: Double) -> Double {
        Double(min(index, 12)) * gap
    }

    /// How far through a move lasting `duration` that starts `delay` seconds after its section arrived: 0 before,
    /// 1 after, and 1 once built (`time` nil).
    static func progress(_ time: Double?, _ delay: Double, _ duration: Double) -> Double {
        guard let time else { return 1 }
        return min(max((time - delay) / duration, 0), 1)
    }

    /// Where `progress` sits between two keyframes, 0 to 1.
    static func segment(_ progress: Double, _ from: Double, _ to: Double) -> Double {
        min(max((progress - from) / (to - from), 0), 1)
    }

    /// jh-flicker, a display element powering on with a stutter: each keyframe's opacity held until the next.
    static func flicker(_ progress: Double) -> Double {
        let frames = [(0.0, 0.0), (0.2, 1), (0.32, 0.15), (0.46, 0.9), (0.58, 0.35), (0.72, 1)]
        return frames.last { $0.0 <= progress }?.1 ?? 0
    }

    /// jh-typeline: the share of a line revealed, in 24 character-sized steps.
    static func typed(_ progress: Double) -> Double {
        (progress * 24).rounded(.down) / 24
    }

    /// jh-breathe, a live dot: opacity 1 → 0.55 → 1 over 3.2 s on the ambient curve.
    static func breathe(_ seconds: Double) -> Double {
        let half = seconds.truncatingRemainder(dividingBy: 3.2) / 1.6
        return 1 - 0.45 * ambient(half < 1 ? half : 2 - half)
    }

    /// jh-blink: on for the first half of each `period`, off for the second (a hair early, so a redraw due exactly on
    /// the half never lands on the wrong side of it).
    static func blink(_ seconds: Double, period: Double = 1) -> Bool {
        Int((seconds * 2 / period + 1e-6).rounded(.down)).isMultiple(of: 2)
    }

    /// The moments a part of the build redraws: `fps` times a second from `now` until it settles, `until` seconds
    /// after its section arrives, and two frames past that, as a timeline can leave out its last moment. None once
    /// built.
    static func frames(start: Date?, at: Double, until: Double, fps: Double, now: Date) -> [Date] {
        guard let start else { return [] }
        let end = start.addingTimeInterval(at + until)
        guard end > now else { return [] }
        return Array(stride(from: now, to: end.addingTimeInterval(2 / fps), by: 1 / fps))
    }

    private static let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("0123456789")

    /// ScrambleText's frames, 20 a second over its 650 ms, worked out at once so no frame does string work.
    static func scrambles(_ text: String) -> [String] {
        (0 ..< 13).map { scramble(text, Double($0) / 13, tick: $0) }
    }

    /// ScrambleText: the first `resolved` share of the characters read true; letters and digits after them cycle
    /// through others of their kind, a new draw each `tick`. Everything else holds still.
    static func scramble(_ text: String, _ resolved: Double, tick: Int) -> String {
        guard resolved < 1 else { return text }
        let done = Int(Double(text.count) * resolved)
        return String(text.enumerated().map { index, character in
            guard index >= done, character.isASCII, character.isLetter || character.isNumber else { return character }
            let pool = character.isNumber ? digits : letters
            let pick = pool[Int(HUDAscii.hash(Double(index), Double(tick), Double(text.count + 3)) * Double(pool.count))]
            return character.isLowercase ? Character(pick.lowercased()) : pick
        })
    }

    /// Character art arriving top to bottom: rows below the front are blank, rows at the front are ramp noise
    /// (redrawn each `tick`), rows above it read true. Only the few rows at the front are rewritten, byte by byte
    /// (art is ASCII); the rest are dropped or passed through untouched.
    static func resolve(_ lines: [String], _ progress: Double, tick: Int, seed: Double = 1) -> [String] {
        guard progress < 1 else { return lines }
        let front = progress * Double(lines.count + 8) - 4
        return lines.enumerated().map { row, line in
            let down = Double(row)
            if down > front + 2 {
                return ""
            }
            if down < front - 2 {
                return line
            }
            var bytes = Array(line.utf8)
            for col in bytes.indices where bytes[col] != 0x20 && HUDAscii.hash(Double(col), down, seed + Double(tick)) < 0.7 {
                bytes[col] = rampBytes[1 + Int(HUDAscii.hash(down, Double(col), Double(tick)) * Double(rampBytes.count - 1))]
            }
            return String(bytes: bytes, encoding: .utf8) ?? line
        }
    }

    private static let rampBytes = Array(" .:-=+*#%@".utf8)
}

/// Where the build-on stands for a view: when it started (nil once built, under Reduce Motion and outside the
/// shell) and when the view's section arrives, in seconds from the start (the design's `--jh-at`).
struct HUDArrival {
    var start: Date?
    var at = 0.0

    /// Seconds since the section arrived, or nil when everything shows settled.
    func elapsed(_ date: Date) -> Double? {
        start.map { date.timeIntervalSince($0) - at }
    }
}

extension EnvironmentValues {
    @Entry var hudArrival = HUDArrival()
    /// False while a view around this one is still arriving. Glows wait until it has, since the window server would
    /// re-blur a moving glow every frame.
    @Entry var hudSteady = true
}

/// Redraws `content` through its own part of the build-on with the seconds since its section arrived (nil once
/// built): at most 20 times a second (the cables' rate), only while the panel shows, and only until the part settles
/// `until` seconds after its section arrives.
struct HUDBuildClock<Content: View>: View {
    var until: Double
    var fps = 20.0
    @ViewBuilder var content: (Double?) -> Content
    @Environment(\.hudArrival) private var arrival

    var body: some View {
        let frames = HUDPresence.shared.open
            ? HUDMotion.frames(start: arrival.start, at: arrival.at, until: until, fps: fps, now: Date()) : []
        TimelineView(.explicit(frames)) { context in
            content(arrival.elapsed(context.date))
        }
    }
}

/// Redraws `content` every `every` seconds, with the seconds since it started, while `running`, the panel shows and
/// Reduce Motion is off (nil otherwise): the loops of live things, like the breathing dot and the caret.
struct HUDLiveClock<Content: View>: View {
    var running = true
    var every = 1.0 / 20
    @ViewBuilder var content: (Double?) -> Content
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        if running, !still, HUDPresence.shared.open {
            let anchor = Date()
            TimelineView(.periodic(from: anchor, by: every)) { context in
                content(context.date.timeIntervalSince(anchor))
            }
        } else {
            content(nil)
        }
    }
}

/// The arrivals in Motion.md that other views share.
enum HUDMove {
    /// Fades in over a duration on a curve.
    case fade(Double, HUDMotion.Curve)
    /// Powers on with a stutter over a duration, in steps.
    case flicker(Double)
    /// Moves into place from an offset while fading in, 260 ms on the enter curve.
    case shift(CGFloat, CGFloat)
    /// Types out left to right in 24 steps over 240 ms: log rows.
    case type
    /// A soft-edged wipe left to right over a duration.
    case wipe(Double)
    /// Opens from a line across the middle over a duration (jh-open); `traces` adds the shell's traced edges.
    case open(Double, traces: Bool)

    /// Chat messages rise into place; notifications slide in from the left.
    static let rise = HUDMove.shift(0, 6)
    static let slide = HUDMove.shift(-12, 0)

    /// How long the move runs.
    var length: Double {
        switch self {
        case let .fade(duration, _), let .flicker(duration), let .wipe(duration): duration
        case .shift: 0.26
        case .type: 0.24
        case let .open(duration, traces): traces ? duration * 760 / 700 : duration
        }
    }
}

extension View {
    /// Arrives in the build-on with `move`, `delay` seconds after its section; shows settled once built.
    func hudArrive(_ move: HUDMove, after delay: Double = 0) -> some View {
        modifier(HUDArrive(move: move, delay: delay))
    }
}

private struct HUDArrive: ViewModifier {
    let move: HUDMove
    let delay: Double
    @Environment(\.hudSteady) private var steady

    func body(content: Content) -> some View {
        HUDBuildClock(until: delay + move.length) { time in
            Group {
                switch move {
                case let .fade(duration, curve):
                    content.opacity(curve(HUDMotion.progress(time, delay, duration)))
                case let .flicker(duration):
                    content.opacity(HUDMotion.flicker(HUDMotion.progress(time, delay, duration)))
                case let .shift(across, down):
                    let shown = HUDMotion.enter(HUDMotion.progress(time, delay, 0.26))
                    content.opacity(shown).offset(x: across * (1 - shown), y: down * (1 - shown))
                case .type:
                    content.clipShape(HUDReveal(share: HUDMotion.typed(HUDMotion.progress(time, delay, 0.24))))
                case let .wipe(duration):
                    // The mask only while wiping: a mask draws offscreen.
                    if HUDMotion.progress(time, delay, duration) < 1 {
                        let edge = 2 * HUDMotion.standard(HUDMotion.progress(time, delay, duration))
                        content.mask {
                            LinearGradient(
                                colors: [.black, .clear], startPoint: UnitPoint(x: edge - 0.8, y: 0.5), endPoint: UnitPoint(
                                    x: edge - 0.2,
                                    y: 0.5
                                )
                            )
                        }
                    } else {
                        content
                    }
                case let .open(duration, traces):
                    let progress = HUDMotion.progress(time, delay, duration)
                    content
                        .overlay {
                            if traces, progress < 1 {
                                HUDTraces(progress: HUDMotion.progress(time, delay, duration * 760 / 700))
                            }
                        }
                        .clipShape(HUDOpening(progress: progress))
                }
            }
            .environment(\.hudSteady, steady && HUDMotion.progress(time, delay, move.length) >= 1)
        }
    }
}

/// The part of a line typed so far, from the left edge; whole, it leaves room for glows.
private struct HUDReveal: Shape {
    var share: Double

    func path(in rect: CGRect) -> Path {
        var box = rect.insetBy(dx: -32, dy: -32)
        if share < 1 {
            box.size.width = 32 + rect.width * share
        }
        return Path(box)
    }
}

/// jh-open's clip: a point stretches into a 2-point line across the middle, then the line opens into the box. Open,
/// it leaves room for glows.
struct HUDOpening: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        guard progress < 1 else { return Path(rect.insetBy(dx: -64, dy: -64)) }
        let width = rect.width * HUDMotion.standard(HUDMotion.segment(progress, 0, 0.38))
        let height = 2 + (rect.height - 2) * HUDMotion.standard(HUDMotion.segment(progress, 0.38, 1))
        return Path(CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
    }
}

/// jh-trace: two lines grow along the middle, part to the top and bottom edges, then hand over to the real edges.
/// No glow: they move every frame.
private struct HUDTraces: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let middle = proxy.size.height / 2
            let part = HUDMotion.standard(HUDMotion.segment(progress, 0.38, 0.85))
            ForEach([-1.0, 1.0], id: \.self) { side in
                Rectangle().fill(HUD.frame).frame(height: 1)
                    .scaleEffect(x: HUDMotion.standard(HUDMotion.segment(progress, 0, 0.38)), y: 1)
                    .position(x: proxy.size.width / 2, y: middle + side * (middle - 0.5) * part)
            }
            .opacity(1 - HUDMotion.standard(HUDMotion.segment(progress, 0.85, 1)))
        }
        .allowsHitTesting(false)
    }
}

/// The rule an inset section draws across as it arrives (jh-rule), fading to the hairline under it. No glow: it
/// moves every frame.
struct HUDRuleTrace: View {
    var body: some View {
        HUDBuildClock(until: 0.52) { time in
            let progress = HUDMotion.progress(time, 0, 0.52)
            if progress < 1 {
                Rectangle().fill(HUD.frame).frame(height: 1)
                    .scaleEffect(x: HUDMotion.standard(HUDMotion.segment(progress, 0, 0.6)), y: 1, anchor: .leading)
                    .opacity(1 - HUDMotion.standard(HUDMotion.segment(progress, 0.6, 1)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// ScrambleText: a value whose letters and digits cycle, then settle left to right over 650 ms, `delay` after its
/// section arrives, 20 frames a second. A `glow`ing (live) value lights up once it has settled. VoiceOver reads the
/// true value.
struct HUDScramble: View {
    let text: String
    var delay = 0.5
    var glow = false
    @Environment(\.hudArrival) private var arrival

    var body: some View {
        // Worked out once per value and only while building, never in a frame.
        let frames = arrival.start == nil ? [] : HUDMotion.scrambles(text)
        HUDBuildClock(until: delay + 0.65) { time in
            let frame = time.map { Int((($0 - delay) * 20).rounded(.down)) } ?? frames.count
            Text(frame < frames.count ? frames[max(frame, 0)] : text)
                .hudGlow(active: glow && frame >= frames.count)
                .accessibilityLabel(text)
        }
    }
}

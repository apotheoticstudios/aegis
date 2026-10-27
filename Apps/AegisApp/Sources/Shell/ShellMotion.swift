import Foundation

/// AegisShell's engage and disengage (the design system's ShellEngage, Motion.md › AegisShell) as pure functions of
/// time, so the transition can be drawn, and tested, at any moment. Geometry glides, text steps.
enum ShellMotion {
    /// How far each layer of the desktop has arrived, 0 to 1.
    struct Frame: Equatable {
        /// The whole desktop.
        var all = 1.0
        /// The wash.
        var wall = 1.0
        /// The share of the frame's line drawn, and its opacity.
        var trace = 1.0
        var traceFade = 1.0
        /// The frame's corner brackets.
        var brackets = 1.0
        /// Character noise from the density ramp over the screen.
        var noise = 0.0
        /// The shield forming over the screen, and its scale.
        var shield = 0.0
        var shieldScale = 1.12
        /// The core: the reactor in today's schedule arc.
        var core = 1.0
        /// Aegis's line under the core, and every reading drawn round it.
        var readings = 1.0
    }

    /// Built: from here only live things move.
    static let engaged = 1.9
    static let disengaged = 1.0
    /// Under Reduce Motion, one crossfade each way.
    static let reduced = 0.3
    /// The Dock returns 600 ms into disengaging.
    static let dockReturns = 0.6
    /// The Aegis menu bar item shows the workspace, the status and Exit at 900 ms.
    static let itemShows = 0.9

    /// `time` seconds into engaging. `traceLength` is the frame's line in points: the design draws it as a 6000-point
    /// dash, so a shorter line finishes early in the 700 ms.
    static func engage(_ time: Double, traceLength: Double, reduced: Bool) -> Frame {
        guard !reduced else { return Frame(all: span(time, 0, Self.reduced)) }
        let shield = span(time, 0.25, 1.5)
        return Frame(
            wall: HUDMotion.enter(span(time, 0.5, 0.8)),
            trace: min(1, 6000 * HUDMotion.standard(span(time, 0.2, 0.7)) / max(traceLength, 1)),
            brackets: steps(span(time, 0.76, 0.2), 2),
            noise: keyframes(span(time, 0.42, 0.9), [(0, 0), (0.2, 0.55), (0.6, 0.35), (1, 0)]) { steps($0, 9) },
            shield: keyframes(shield, [(0, 0), (0.35, 0.9), (0.7, 0.6), (1, 0)], HUDMotion.standard.callAsFunction),
            shieldScale: keyframes(shield, [(0, 0.6), (0.7, 1.04), (1, 1.12)], HUDMotion.standard.callAsFunction),
            core: steps(span(time, 0.8, 0.26), 3),
            readings: HUDMotion.standard(span(time, 1.2, 0.48))
        )
    }

    /// `time` seconds into disengaging: the readings go together, then the desktop and the frame.
    static func disengage(_ time: Double, reduced: Bool) -> Frame {
        guard !reduced else { return Frame(all: 1 - span(time, 0, Self.reduced)) }
        return Frame(
            all: 1 - HUDMotion.exit(span(time, 0, 0.8)),
            traceFade: 1 - HUDMotion.ease(span(time, 0.45, 0.3)),
            readings: 1 - HUDMotion.exit(span(time, 0, 0.3))
        )
    }

    /// Progress through a move of `duration` starting at `delay`, held at 0 before and 1 after.
    static func span(_ time: Double, _ delay: Double, _ duration: Double) -> Double {
        min(max((time - delay) / duration, 0), 1)
    }

    /// CSS's `steps(count, end)`.
    static func steps(_ progress: Double, _ count: Double) -> Double {
        progress >= 1 ? 1 : (progress * count).rounded(.down) / count
    }

    /// A CSS keyframe track: the timing function applies to each interval between keyframes.
    static func keyframes(_ progress: Double, _ frames: [(Double, Double)], _ timing: (Double) -> Double) -> Double {
        guard let after = frames.firstIndex(where: { $0.0 > progress }) else { return frames.last?.1 ?? 0 }
        guard after > 0 else { return frames[0].1 }
        let (from, start) = frames[after - 1], (to, end) = frames[after]
        return start + (end - start) * timing((progress - from) / (to - from))
    }
}

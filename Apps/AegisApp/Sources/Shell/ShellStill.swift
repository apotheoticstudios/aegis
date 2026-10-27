import Foundation

/// Why AegisShell's desktop holds still (the design system's ShellDesktopStill): the core, the art, the rings and the
/// pings stop and the frame holds, with a line along the bottom saying why. It resumes by itself when the reason goes.
/// It keeps moving on battery (owner's choice, 2026-10-27).
enum ShellStill: Equatable {
    case busy, reduceMotion, held, covered

    /// The first reason that applies, most pressing first.
    static func reason(thermal: ProcessInfo.ThermalState, reduceMotion: Bool, held: Bool, covered: Bool) -> ShellStill? {
        if thermal == .serious || thermal == .critical {
            return .busy
        }
        if reduceMotion {
            return .reduceMotion
        }
        return held ? .held : covered ? .covered : nil
    }

    /// The line along the bottom.
    var line: String {
        switch self {
        case .busy: "The Mac is busy: the live desktop holds still until it cools down."
        case .reduceMotion: "Reduce Motion is on: the live desktop holds still."
        case .held: "Held still from Aegis's menu."
        case .covered: "Covered by windows: the live desktop holds still until you can see it."
        }
    }
}

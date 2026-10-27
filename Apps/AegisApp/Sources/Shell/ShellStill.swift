import Foundation
import IOKit.ps

/// Why AegisShell's desktop holds still (the design system's ShellDesktopStill): the core, the art, the rings and the
/// pings stop and the frame holds, with a line along the bottom saying why. It resumes by itself when the reason goes.
enum ShellStill: Equatable {
    case battery, busy, reduceMotion, held, covered

    /// The first reason that applies, most pressing first.
    static func reason(battery: Bool, thermal: ProcessInfo.ThermalState, reduceMotion: Bool, held: Bool, covered: Bool) -> ShellStill? {
        if battery {
            return .battery
        }
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
        case .battery: "On battery: the live desktop holds still and uses no GPU. It resumes when you plug in."
        case .busy: "The Mac is busy: the live desktop holds still until it cools down."
        case .reduceMotion: "Reduce Motion is on: the live desktop holds still."
        case .held: "Held still from Aegis's menu."
        case .covered: "Covered by windows: the live desktop holds still until you can see it."
        }
    }

    /// Whether the Mac is running on its battery.
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return source as String == kIOPMBatteryPowerKey
    }
}

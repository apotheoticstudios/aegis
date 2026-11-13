@testable import Aegis
import AppKit
import IOKit.ps
import XCTest

/// AegisShell's bar (ADR-0033): where it sits on each menu bar, and what its right side reads. Synthetic power-source
/// descriptions only.
@MainActor
final class ShellBarTests: XCTestCase {
    func testTheBarCoversEachMenuBar() {
        // A notched MacBook: the whole menu bar, with the room either side of the notch.
        let mac = NSRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(
            ShellMenuBar.layout(
                screen: mac,
                visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                notchLeft: NSRect(x: 0, y: 944, width: 654, height: 38),
                notchRight: NSRect(x: 858, y: 944, width: 654, height: 38)
            ),
            .init(frame: NSRect(x: 0, y: 944, width: 1512, height: 38), left: 654, right: 654)
        )
        // A display without a notch, to the right of the main one and with the Dock on its left: halves either side.
        let wide = NSRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(
            ShellMenuBar.layout(
                screen: wide,
                visible: NSRect(x: 1560, y: -200, width: 2512, height: 1415),
                notchLeft: nil,
                notchRight: nil
            ),
            .init(frame: NSRect(x: 1512, y: 1215, width: 2560, height: 25), left: 1280, right: 1280)
        )
        // No menu bar taking room (it hides itself, or the display has none): no bar, so no window's buttons are covered.
        XCTAssertNil(ShellMenuBar.layout(screen: wide, visible: wide, notchLeft: nil, notchRight: nil))
        XCTAssertEqual(ShellBar.help("Focus", "⌃2"), "Focus (⌃2)")
        XCTAssertEqual(ShellBar.help("Talk", nil), "Talk")
    }

    func testTheBarReadsTheBatteryAndNetwork() {
        func battery(_ extra: [String: Any]) -> ShellSystemStatus.Battery? {
            ShellSystemStatus.battery([
                kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 62, kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            ].merging(extra) { $1 })
        }
        XCTAssertEqual(battery([:]), .init(level: 62, charging: false, plugged: false))
        XCTAssertEqual(
            battery([kIOPSIsChargingKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue]),
            .init(level: 62, charging: true, plugged: true)
        )
        // A battery that reports its capacity in mAh still reads as a percentage.
        XCTAssertEqual(battery([kIOPSCurrentCapacityKey: 2500, kIOPSMaxCapacityKey: 5000])?.level, 50)
        // A UPS or a battery with no capacity isn't the Mac's own.
        XCTAssertNil(battery([kIOPSTypeKey: kIOPSUPSType]))
        XCTAssertNil(battery([kIOPSMaxCapacityKey: 0]))
        XCTAssertEqual(ShellBarReadings.spoken(.init(level: 62, charging: true, plugged: true)), "Battery 62%, charging")
        XCTAssertEqual(ShellBarReadings.spoken(.init(level: 100, charging: false, plugged: true)), "Battery 100%, on power")
        XCTAssertEqual(ShellBarReadings.spoken(.init(level: 9, charging: false, plugged: false)), "Battery 9%")
        // The network is a kind, never its name.
        XCTAssertEqual(ShellBarReadings.words(.wifi).spoken, "Wi-Fi")
        XCTAssertEqual(ShellBarReadings.words(.offline).icon, .offline)
    }
}

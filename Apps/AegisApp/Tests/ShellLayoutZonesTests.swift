@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// The window layout's zones and glide (#198, the design system's ShellWindows).
@MainActor
final class ShellLayoutZonesTests: XCTestCase {
    func testZonesSitWhereTheWindowsWillGo() {
        // Accessibility measures from the main display's top left; the overlay from its own top left.
        let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let zone = CGRect(x: 8, y: 45, width: 723, height: 903)
        XCTAssertEqual(ShellLayoutZones.local(zone, screen: main, primary: main), zone)
        // A display to the right, its top 200 points above the main display's.
        let side = CGRect(x: 1470, y: -44, width: 2560, height: 1200)
        XCTAssertEqual(
            ShellLayoutZones.local(CGRect(x: 1478, y: -150, width: 600, height: 400), screen: side, primary: main),
            CGRect(x: 8, y: 50, width: 600, height: 400)
        )
    }

    func testWindowsGlideOnTheStandardCurve() {
        let from = CGRect(x: 100, y: 100, width: 400, height: 300), to = CGRect(x: 8, y: 45, width: 723, height: 903)
        XCTAssertEqual(ShellLayoutZones.step(from: from, to: to, progress: 0), from)
        XCTAssertEqual(ShellLayoutZones.step(from: from, to: to, progress: 1), to)
        XCTAssertEqual(ShellLayoutZones.step(from: from, to: to, progress: 1.4), to, "held once there")
        XCTAssertEqual(ShellLayoutZones.step(from: from, to: to, progress: -0.2), from)
        // Eased: well past halfway at half time, as ease-standard (0.2, 0, 0, 1) is.
        let half = ShellLayoutZones.step(from: from, to: to, progress: 0.5)
        XCTAssertGreaterThan((half.width - from.width) / (to.width - from.width), 0.6)
        XCTAssertLessThan(half.width, to.width)
    }

    /// Renders the zones for two windows at the MacBook's size. Opt-in: `TEST_RUNNER_AEGIS_RENDER_SHELL=<folder>`.
    func testRendersTheZones() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_RENDER_SHELL"] else {
            throw XCTSkip("Set AEGIS_RENDER_SHELL to a folder to render AegisShell.")
        }
        let size = CGSize(width: 1470, height: 956)
        let zones = [
            ShellLayoutZones.Zone(
                name: "Mail",
                from: CGRect(x: 400, y: 200, width: 700, height: 500),
                to: CGRect(x: 8, y: 45, width: 723, height: 903)
            ),
            ShellLayoutZones.Zone(
                name: "Calendar",
                from: CGRect(x: 300, y: 300, width: 600, height: 420),
                to: CGRect(x: 739, y: 45, width: 723, height: 903)
            ),
        ]
        let host = NSHostingView(rootView: ShellLayoutZonesView(zones: zones, size: size).background(Color(white: 0.12)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("zones.png"))
    }
}

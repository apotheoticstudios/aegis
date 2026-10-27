@testable import Aegis
import AegisKit
import AppKit
import SwiftUI
import XCTest

/// AegisShell, stage 1 (ADR-0033): macOS is put back exactly as it was, and the engage transition keeps the design's
/// timing. A fake Dock and a temporary file: the owner's real Dock is never touched.
@MainActor
final class ShellTests: XCTestCase {
    private final class FakeDock: ShellDock {
        var value: Bool?
        var works = true
        private(set) var changes = 0

        init(_ value: Bool) {
            self.value = value
        }

        func autohide() -> Bool? {
            value
        }

        func set(autohide: Bool) async -> Bool {
            setNow(autohide: autohide)
        }

        func setNow(autohide: Bool) -> Bool {
            guard works else { return false }
            value = autohide
            changes += 1
            return true
        }
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)/shell-state.json")
    }

    func testTwentyEngagesLeaveTheDockAsItWas() async {
        for original in [false, true] {
            let dock = FakeDock(original), url = file()
            let settings = ShellSettings(dock: dock, file: url)
            for _ in 0 ..< 20 {
                let hidden = await settings.apply()
                XCTAssertTrue(hidden)
                XCTAssertEqual(dock.value, true, "the Dock hides while engaged")
                let restored = await settings.restore()
                XCTAssertTrue(restored)
                XCTAssertEqual(dock.value, original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing left behind")
            }
            XCTAssertEqual(dock.changes, original ? 0 : 40, "an owner who hides the Dock anyway sees no change")
        }
    }

    func testACrashIsUndoneAtTheNextLaunch() async {
        let dock = FakeDock(false), url = file()
        _ = await ShellSettings(dock: dock, file: url).apply()
        // Aegis dies here; a new launch finds the saved file.
        let next = ShellSettings(dock: dock, file: url)
        XCTAssertEqual(next.saved, ShellSettings.Saved(dockAutohide: false))
        // Engaging again before the restore keeps the owner's own setting, not the hidden one.
        _ = await next.apply()
        XCTAssertEqual(next.saved, ShellSettings.Saved(dockAutohide: false))
        XCTAssertTrue(next.restoreNow())
        XCTAssertEqual(dock.value, false)
        XCTAssertNil(next.saved)
    }

    func testAFailedRestoreIsKeptForTheNextTry() async {
        let dock = FakeDock(false), url = file()
        let settings = ShellSettings(dock: dock, file: url)
        _ = await settings.apply()
        dock.works = false
        let failed = await settings.restore()
        XCTAssertFalse(failed)
        XCTAssertNotNil(settings.saved, "kept, so the next launch tries again")
        dock.works = true
        let restored = await settings.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(dock.value, false)
        // Nothing saved when the Dock can't be read: nothing is changed either.
        let unknown = FakeDock(false)
        unknown.value = nil
        let refused = await ShellSettings(dock: unknown, file: file()).apply()
        XCTAssertFalse(refused)
        XCTAssertEqual(unknown.changes, 0)
    }

    /// Codex's review of #74: disengaging while the Dock is still being hidden must restore it after the hide.
    func testARestoreWaitsForAHideUnderWay() async {
        final class SlowDock: ShellDock {
            var value: Bool? = false
            var gate: CheckedContinuation<Void, Never>?
            var waiting: CheckedContinuation<Void, Never>?

            func autohide() -> Bool? {
                value
            }

            func set(autohide: Bool) async -> Bool {
                if autohide {
                    // The hide is slow: it waits until the test lets it through.
                    await withCheckedContinuation { gate = $0
                        waiting?.resume()
                    }
                }
                value = autohide
                return true
            }

            func setNow(autohide: Bool) -> Bool {
                value = autohide
                return true
            }
        }
        let dock = SlowDock(), settings = ShellSettings(dock: dock, file: file()), queue = ShellQueue()
        let hiding = Task { await queue.run { _ = await settings.apply() } }
        await withCheckedContinuation { dock.waiting = $0 }
        let restoring = Task { await queue.run { await settings.restore() } }
        dock.gate?.resume()
        await hiding.value
        await restoring.value
        XCTAssertEqual(dock.value, false, "the Dock is back as it was")
        XCTAssertNil(settings.saved, "nothing left to restore")
    }

    /// The design's timing: ShellEngage's table.
    func testEngageAndDisengageKeepTheDesignsTiming() {
        let start = ShellMotion.engage(0, traceLength: 2000, reduced: false)
        XCTAssertEqual(start.wall, 0)
        XCTAssertEqual(start.core, 0)
        XCTAssertEqual(start.readings, 0)
        XCTAssertEqual(start.shield, 0)
        XCTAssertEqual(start.shieldScale, 0.6, accuracy: 1e-9)
        XCTAssertEqual(start.trace, 0)
        XCTAssertGreaterThan(ShellMotion.engage(0.6, traceLength: 2000, reduced: false).noise, 0.3, "noise flickers from 420 ms")
        XCTAssertEqual(ShellMotion.engage(0.9, traceLength: 2000, reduced: false).brackets, 0.5, "brackets flicker on in two steps")
        let shield = ShellMotion.engage(0.25 + 0.35 * 1.5, traceLength: 2000, reduced: false)
        XCTAssertEqual(shield.shield, 0.9, accuracy: 1e-9)
        XCTAssertEqual(ShellMotion.engage(0.9, traceLength: 2000, reduced: false).core, 1.0 / 3, accuracy: 1e-9, "the core steps on")
        let built = ShellMotion.engage(ShellMotion.engaged, traceLength: 2000, reduced: false)
        XCTAssertEqual(built.wall, 1, accuracy: 0.01)
        XCTAssertEqual(built.trace, 1)
        XCTAssertEqual(built.core, 1)
        XCTAssertEqual(built.readings, 1, accuracy: 0.01)
        XCTAssertEqual(built.noise, 0)
        XCTAssertEqual(built.shield, 0)
        XCTAssertEqual(ShellMotion.disengage(0.3, reduced: false).readings, 0, "the readings go first")
        XCTAssertGreaterThan(ShellMotion.disengage(0.3, reduced: false).all, 0)
        XCTAssertEqual(ShellMotion.disengage(0.8, reduced: false).all, 0)
        // Reduce Motion: one 300 ms crossfade, no shield, no noise.
        let reduced = ShellMotion.engage(0.15, traceLength: 2000, reduced: true)
        XCTAssertEqual(reduced.all, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reduced.shield, 0)
        XCTAssertEqual(reduced.noise, 0)
        XCTAssertEqual(ShellMotion.disengage(0.3, reduced: true).all, 0)
    }

    func testTheLineUnderTheCoreHasNoNames() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lunch = HUDScheduleArc.Event(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), title: "Lunch with Sam")
        XCTAssertEqual(ShellDesktop.need(0), "All clear.")
        XCTAssertEqual(ShellDesktop.need(1), "One thing needs you.")
        XCTAssertEqual(ShellDesktop.need(2), "Two things need you.")
        XCTAssertEqual(ShellDesktop.need(14), "14 things need you.")
        XCTAssertEqual(ShellDesktop.next([lunch], now: now), "Your next event is at \(HUDScheduleArc.clock(lunch.start)).")
        XCTAssertEqual(ShellDesktop.next([lunch], now: lunch.end), "Nothing else today.")
        XCTAssertEqual(ShellMenu.caps("⌥⇧Space"), ["⌥", "⇧", "Space"])
        XCTAssertEqual(ShellMenu.caps("⌃⌥A"), ["⌃", "⌥", "A"])
    }

    func testTheDesktopHoldsStillForTheRightReason() {
        func reason(
            battery: Bool = false,
            thermal: ProcessInfo.ThermalState = .nominal,
            motion: Bool = false,
            held: Bool = false,
            covered: Bool = false
        )
            -> ShellStill?
        {
            ShellStill.reason(battery: battery, thermal: thermal, reduceMotion: motion, held: held, covered: covered)
        }
        XCTAssertNil(reason(), "live")
        XCTAssertNil(reason(thermal: .fair))
        XCTAssertEqual(reason(battery: true, held: true, covered: true), .battery, "most pressing first")
        XCTAssertEqual(reason(thermal: .serious), .busy)
        XCTAssertEqual(reason(motion: true, held: true), .reduceMotion)
        XCTAssertEqual(reason(held: true, covered: true), .held)
        XCTAssertEqual(reason(covered: true), .covered)
        XCTAssertTrue(ShellStill.battery.line.contains("plug in"))
    }

    func testTheReadingsWording() {
        XCTAssertEqual(ShellReadings.toGo(25 * 60 - 10).value, "25")
        XCTAssertEqual(ShellReadings.toGo(25 * 60).unit, "min to go")
        XCTAssertEqual(ShellReadings.toGo(3 * 3600).value, "3")
        XCTAssertEqual(ShellReadings.toGo(3 * 3600).unit, "h to go")
        XCTAssertEqual(ShellReadings.since(26 * 3600), "26 h")
        XCTAssertEqual(ShellReadings.since(52 * 60), "52 min")
        XCTAssertEqual(ShellReadings.tone(26 * 3600), .critical)
        XCTAssertEqual(ShellReadings.tone(9 * 3600), .warn)
        XCTAssertEqual(ShellReadings.tone(3 * 3600), .ink)
        XCTAssertEqual(ShellReadings.tone(20 * 60), .inkMuted)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = HUDScheduleArc.Event(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), title: "Lunch")
        XCTAssertEqual(ShellReadings.left([later], now: now), "1 event left today")
        XCTAssertEqual(ShellReadings.left([later], now: later.end), "Nothing else today")
        XCTAssertEqual(ShellDesktop.next([later], now: now, hidden: false), "Lunch at \(HUDScheduleArc.clock(later.start)).")
    }

    /// Renders the desktop at the MacBook's size through the transition and built, the menu bar item and its menu, to
    /// compare with the design's AegisShell cards. Opt-in: `TEST_RUNNER_AEGIS_RENDER_SHELL=<folder>`.
    func testRendersTheShell() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_RENDER_SHELL"] else {
            throw XCTSkip("Set AEGIS_RENDER_SHELL to a folder to render AegisShell.")
        }
        let shell = ShellController()
        shell.model = PanelModel(service: SampleCoreService(), actions: nil)
        let day = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Double, _ minutes: Double, _ title: String) -> HUDScheduleArc.Event {
            HUDScheduleArc.Event(
                start: day.addingTimeInterval(hour * 3600), end: day.addingTimeInterval(hour * 3600 + minutes * 60), title: title
            )
        }
        let now = day.addingTimeInterval(11 * 3600 + 5 * 60)
        shell.readings = .init(
            urgent: 2, top: "Sam: can you call me about Saturday?", topFromPerson: true, items: 6,
            events: [at(9, 20, "Standup"), at(11.5, 45, "Design review"), at(13, 60, "Lunch"), at(16, 30, "Call"), at(19, 90, "Training")],
            waiting: [("Sam", 26.0), ("Alex", 9), ("Mum", 3), ("Priya", 0.9), ("Jake", 0.3)]
                .map { .init(name: $0.0, since: now.addingTimeInterval(-$0.1 * 3600)) },
            problems: [.mail], diskUsed: 31_000_000_000, diskTotal: 40_000_000_000, memory: 2_100_000_000, now: now
        )
        shell.hideDetails = false
        HUDPresence.shared.shell = true
        defer { HUDPresence.shared.shell = false }
        func snap(_ view: some View, _ size: CGSize, _ name: String) throws {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        let size = CGSize(width: 1470, height: 956)
        for moment in [0.5, 0.9, 1.3] {
            shell.phase = .engaging(Date().addingTimeInterval(-moment + 0.3))
            try snap(ShellDesktop(shell: shell, size: size, top: 37), size, "engage-\(Int(moment * 1000)).png")
        }
        shell.phase = .engaged
        try snap(ShellDesktop(shell: shell, size: size, top: 37), size, "desktop.png")
        shell.hideDetails = true
        shell.still = .battery
        try snap(ShellDesktop(shell: shell, size: size, top: 37), size, "desktop-hidden-still.png")
        shell.still = nil
        try snap(
            ShellDesktop(shell: shell, size: CGSize(width: 2560, height: 1440), top: 25),
            CGSize(width: 2560, height: 1440),
            "desktop-27.png"
        )
        try snap(ShellMenuExtra(shell: shell).background(Color(white: 0.08)), CGSize(width: 260, height: 24), "item-engaging.png")
        shell.itemComplete = true
        shell.panelKey = "⌥Space"
        try snap(ShellMenuExtra(shell: shell).background(Color(white: 0.08)), CGSize(width: 260, height: 24), "item.png")
        try snap(ShellMenu(shell: shell) {}.background(Color.black), CGSize(width: 320, height: 260), "menu.png")
    }
}

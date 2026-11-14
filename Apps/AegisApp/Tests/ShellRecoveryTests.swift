@testable import Aegis
import XCTest

/// AegisShell keeping macOS and its readings right across quits, clock changes and failed reads (#196). A fake Dock and a
/// temporary file: the owner's real Dock is never touched.
@MainActor
final class ShellRecoveryTests: XCTestCase {
    private final class SlowDock: ShellDock {
        var value: Bool? = false
        var gate: CheckedContinuation<Void, Never>?
        var waiting: CheckedContinuation<Void, Never>?

        func autohide() -> Bool? {
            value
        }

        func set(autohide: Bool) async -> Bool {
            if autohide {
                // The hide is slow: it waits until the test lets it land.
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

    func testQuittingWhileTheDockHidesKeepsTheRecordForTheNextLaunch() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)/shell-state.json")
        let dock = SlowDock(), settings = ShellSettings(dock: dock, file: file)
        let hiding = Task { await settings.apply() }
        await withCheckedContinuation { dock.waiting = $0 }
        // Aegis quits while the hide is still on its way: the Dock goes back, but the record stays.
        XCTAssertFalse(settings.restoreNow())
        XCTAssertEqual(dock.value, false)
        XCTAssertNotNil(settings.saved)
        // The late hide lands after all; the next launch puts the Dock back from the record.
        dock.gate?.resume()
        _ = await hiding.value
        XCTAssertEqual(dock.value, true)
        let restored = await settings.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(dock.value, false)
        XCTAssertNil(settings.saved)
    }

    func testTodayRunsMidnightToMidnightWhenTheClocksChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        func hours(_ year: Int, _ month: Int, _ day: Int) throws -> Double {
            let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
            let today = ShellController.today(noon, calendar: calendar)
            XCTAssertEqual(calendar.component(.hour, from: today.end), 0, "ends at local midnight")
            return today.end.timeIntervalSince(today.start) / 3600
        }
        XCTAssertEqual(try hours(2026, 4, 5), 25, "the clocks go back")
        XCTAssertEqual(try hours(2026, 10, 4), 23, "the clocks go forward")
        XCTAssertEqual(try hours(2026, 11, 14), 24)
    }

    func testARefreshKeepsWhatWasKnownTodayAndStartsFreshTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        var known = ShellController.Readings(now: morning)
        known.events = [HUDScheduleArc.Event(
            start: morning.addingTimeInterval(3600),
            end: morning.addingTimeInterval(7200),
            title: "Event"
        )]
        known.waiting = [.init(name: "Contact", since: morning)]
        // Later the same day: a read that fails keeps these, instead of "Nothing else today".
        let later = ShellController.base(known, now: morning.addingTimeInterval(1800), calendar: calendar)
        XCTAssertEqual(later.events, known.events)
        XCTAssertEqual(later.waiting, known.waiting)
        XCTAssertEqual(later.now, morning.addingTimeInterval(1800))
        // The next day: nothing carried over.
        let tomorrow = ShellController.base(known, now: morning.addingTimeInterval(86400), calendar: calendar)
        XCTAssertEqual(tomorrow, ShellController.Readings(now: morning.addingTimeInterval(86400)))
    }
}

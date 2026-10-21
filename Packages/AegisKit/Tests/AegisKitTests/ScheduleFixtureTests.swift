@testable import AegisKit
import Foundation
import XCTest

/// The Stage 1 fixture generator (#89) and the Swift contract agree on schedule records and their IDs (#97).
final class ScheduleFixtureTests: XCTestCase {
    func testStage1ScheduleRecordsDecodeAndValidate() throws {
        let fixtures = try SwiftReaderFixtures(self, profile: "stage1")
        let calendarData = try Data(contentsOf: fixtures.root.appendingPathComponent("calendar.json"))
        let calendar = try JSONDecoder().decode([CalendarOccurrence].self, from: calendarData)
        XCTAssertFalse(calendar.isEmpty)
        for occurrence in calendar {
            XCTAssertEqual(occurrence.validate(), [], occurrence.itemID)
        }
        XCTAssertEqual(Set(calendar.map(\.id)).count, calendar.count)

        let reminderData = try Data(contentsOf: fixtures.root.appendingPathComponent("reminders.jsonl"))
        let reminders = try reminderData.split(separator: 10).map { try JSONDecoder().decode(ReminderItem.self, from: Data($0)) }
        XCTAssertFalse(reminders.isEmpty)
        for reminder in reminders {
            XCTAssertEqual(reminder.validate(), [], reminder.itemID)
        }

        // The moved stand-up's earlier snapshot is the same occurrence: same ID, earlier time.
        let historyData = try Data(contentsOf: fixtures.root.appendingPathComponent("expected/stage1-history.json"))
        let history = try XCTUnwrap(JSONSerialization.jsonObject(with: historyData) as? [String: Any])
        let moved = try XCTUnwrap(history["standup-moved"] as? [String: Any])
        let previous = try JSONDecoder().decode(
            CalendarOccurrence.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(moved["previous"]))
        )
        XCTAssertEqual(previous.validate(), [])
        let current = try XCTUnwrap(calendar.first { $0.id == previous.id })
        XCTAssertLessThan(previous.start, current.start)
        XCTAssertEqual(current.occurrenceDate, previous.start)
    }
}

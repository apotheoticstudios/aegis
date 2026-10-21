import AegisKit
import Foundation
@testable import MacSources
import XCTest

/// Synthetic values only: no test touches the owner's Calendar, Reminders or Contacts.
final class MappingTests: XCTestCase {
    private let brisbane = TimeZone(identifier: "Australia/Brisbane")!
    private let perth = TimeZone(identifier: "Australia/Perth")!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let captured = ContractTime.parse("2026-10-06T21:05:00Z")!

    private func time(_ text: String) -> Date {
        ContractTime.parse(text)!
    }

    func testSingleEventHasNoOccurrenceDateAndKeepsItsIDWhenMoved() {
        let event = FakeOccurrence(itemID: "ONE", start: time("2026-10-06T23:00:00Z"), timeZone: sydney)
        var moved = event
        moved.start = time("2026-10-07T01:00:00Z")
        moved.end = moved.start.addingTimeInterval(1800)
        let first = ScheduleMapping.occurrence(event, currentZone: brisbane, captureTime: captured)
        let second = ScheduleMapping.occurrence(moved, currentZone: brisbane, captureTime: captured)
        XCTAssertNil(first.occurrenceDate)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.validate(), [])
        XCTAssertEqual(first.timeZone, "Australia/Sydney")
    }

    func testRepeatingOccurrencesUseTheirOriginalDate() {
        var standup = FakeOccurrence(itemID: "STANDUP", start: time("2026-10-06T22:00:00Z"), timeZone: sydney)
        standup.isRepeating = true
        standup.originalDate = standup.start
        var moved = standup
        moved.start = time("2026-10-06T23:00:00Z")
        moved.end = moved.start.addingTimeInterval(1800)
        var nextDay = standup
        nextDay.start = time("2026-10-07T22:00:00Z")
        nextDay.end = nextDay.start.addingTimeInterval(1800)
        nextDay.originalDate = nextDay.start
        let today = ScheduleMapping.occurrence(standup, currentZone: brisbane, captureTime: captured)
        let todayMoved = ScheduleMapping.occurrence(moved, currentZone: brisbane, captureTime: captured)
        let tomorrow = ScheduleMapping.occurrence(nextDay, currentZone: brisbane, captureTime: captured)
        XCTAssertEqual(today.occurrenceDate, time("2026-10-06T22:00:00Z"))
        XCTAssertEqual(today.id, todayMoved.id, "a moved occurrence keeps its ID (case 24)")
        XCTAssertEqual(todayMoved.start, time("2026-10-06T23:00:00Z"))
        XCTAssertNotEqual(today.id, tomorrow.id)
        // EventKit without an occurrence date: the start stands in for it.
        standup.originalDate = nil
        XCTAssertEqual(ScheduleMapping.occurrence(standup, currentZone: brisbane, captureTime: captured).occurrenceDate, standup.start)
    }

    func testFloatingRepeatingAllDayKeepsItsIDAcrossTimeZones() {
        // The same all-day occurrence (6 Oct) as EventKit reports it in Brisbane and after travel to Perth.
        var inBrisbane = FakeOccurrence(itemID: "BIN-DAY", start: time("2026-10-05T14:00:00Z"), timeZone: nil)
        inBrisbane.isAllDay = true
        inBrisbane.isRepeating = true
        inBrisbane.originalDate = inBrisbane.start
        inBrisbane.end = inBrisbane.start.addingTimeInterval(86400)
        var inPerth = inBrisbane
        inPerth.start = time("2026-10-05T16:00:00Z")
        inPerth.end = inPerth.start.addingTimeInterval(86400)
        inPerth.originalDate = inPerth.start
        let fromBrisbane = ScheduleMapping.occurrence(inBrisbane, currentZone: brisbane, captureTime: captured)
        let fromPerth = ScheduleMapping.occurrence(inPerth, currentZone: perth, captureTime: captured)
        XCTAssertEqual(fromBrisbane.id, fromPerth.id, "travel doesn't change the ID (case 27)")
        XCTAssertNil(fromBrisbane.timeZone)
        XCTAssertTrue(fromBrisbane.isAllDay)
        XCTAssertEqual(fromBrisbane.validate(), [])
    }

    func testStatusLocationAndBackwardsTimes() {
        var event = FakeOccurrence(itemID: "CANCELLED", start: time("2026-10-07T00:00:00Z"), timeZone: brisbane)
        event.status = .cancelled
        event.location = ""
        event.end = event.start.addingTimeInterval(-60)
        event.title = nil
        let occurrence = ScheduleMapping.occurrence(event, currentZone: brisbane, captureTime: captured)
        XCTAssertEqual(occurrence.status, .cancelled)
        XCTAssertNil(occurrence.location)
        XCTAssertEqual(occurrence.end, occurrence.start)
        XCTAssertEqual(occurrence.title, "")
        XCTAssertEqual(occurrence.validate(), [])
    }

    func testDateOnlyAndTimedReminders() {
        var bins = FakeReminder(itemID: "BINS")
        bins.due = DateComponents(timeZone: brisbane, year: 2026, month: 10, day: 6)
        let dateOnly = ScheduleMapping.reminder(bins, currentZone: perth, captureTime: captured)
        XCTAssertEqual(dateOnly.due, ReminderItem.Due(date: time("2026-10-05T14:00:00Z"), hasTime: false, timeZone: "Australia/Brisbane"))
        XCTAssertEqual(dateOnly.validate(), [])

        var call = FakeReminder(itemID: "CALL")
        call.due = DateComponents(year: 2026, month: 10, day: 6, hour: 9, minute: 30)
        let timed = ScheduleMapping.reminder(call, currentZone: sydney, captureTime: captured)
        XCTAssertEqual(timed.due, ReminderItem.Due(date: time("2026-10-05T22:30:00Z"), hasTime: true, timeZone: "Australia/Sydney"))

        var none = FakeReminder(itemID: "SOMEDAY")
        none.due = DateComponents(hour: 9)
        XCTAssertNil(ScheduleMapping.reminder(none, currentZone: sydney, captureTime: captured).due, "no day: no due date")
    }

    func testCompletionAndPriorityFollowTheContract() {
        var reminder = FakeReminder(itemID: "UNDONE")
        reminder.completedAt = time("2026-10-06T21:01:00Z")
        reminder.priority = 12
        let open = ScheduleMapping.reminder(reminder, currentZone: brisbane, captureTime: captured)
        XCTAssertNil(open.completedAt, "an uncompleted reminder never keeps a completion time")
        XCTAssertEqual(open.priority, 9)
        XCTAssertEqual(open.validate(), [])
        reminder.isCompleted = true
        reminder.priority = -1
        let done = ScheduleMapping.reminder(reminder, currentZone: brisbane, captureTime: captured)
        XCTAssertEqual(done.completedAt, time("2026-10-06T21:01:00Z"))
        XCTAssertEqual(done.priority, 0)
        XCTAssertEqual(done.validate(), [])
    }

    func testContactNamesAndHandles() {
        let person = FakeContact(
            identifier: "C1", givenName: " Alex ", familyName: "Example", organizationName: "Example Pty",
            phoneNumbers: ["0400 000 001"], emailAddresses: ["alex@example.com"]
        )
        XCTAssertEqual(
            ContactsMapping.snapshot(person),
            ContactSnapshot(id: "C1", displayName: "Alex Example", phones: ["0400 000 001"], emails: ["alex@example.com"])
        )
        let business = FakeContact(identifier: "C2", organizationName: "Example Bank", phoneNumbers: ["12345"])
        XCTAssertEqual(ContactsMapping.snapshot(business).displayName, "Example Bank")
        let unnamed = FakeContact(identifier: "C3", phoneNumbers: ["+61 400 000 003"])
        XCTAssertEqual(ContactsMapping.snapshot(unnamed).displayName, "")
        // An unnamed card still resolves, showing the handle (#92's rule).
        XCTAssertEqual(
            ContactIndex([ContactsMapping.snapshot(unnamed)]).resolve(handle: "+61 400 000 003"),
            .match(.init(id: "C3", name: "+61 400 000 003"))
        )
    }
}

struct FakeOccurrence: CalendarOccurrenceValues {
    var itemID: String
    var calendarTitle: String? = "Example Calendar"
    var title: String? = "Example event"
    var start: Date
    var end: Date
    var isAllDay = false
    var timeZone: TimeZone?
    var location: String? = "Example Room"
    var status: CalendarOccurrence.Status = .confirmed
    var isRepeating = false
    var originalDate: Date?

    init(itemID: String, start: Date, timeZone: TimeZone?) {
        self.itemID = itemID
        self.start = start
        end = start.addingTimeInterval(1800)
        self.timeZone = timeZone
    }
}

struct FakeReminder: ReminderValues {
    var itemID: String
    var listTitle: String? = "Example Reminders"
    var title: String? = "Example reminder"
    var due: DateComponents?
    var isCompleted = false
    var completedAt: Date?
    var priority = 0

    init(itemID: String) {
        self.itemID = itemID
    }
}

struct FakeContact: ContactValues {
    var identifier: String
    var givenName = ""
    var familyName = ""
    var organizationName = ""
    var phoneNumbers: [String] = []
    var emailAddresses: [String] = []
}

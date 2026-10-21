import AegisKit
@testable import AegisStorage
import Foundation
import GRDB
import XCTest

@MainActor
final class StorageScheduleTests: StorageTestCase {
    func testOccurrenceReconciliationIsLimitedToSourceAndOverlappingWindow() async throws {
        let store = try open()
        let rows = [
            occurrence("before", start: -20, end: -10),
            occurrence("ends-at-start", start: -10, end: 0),
            occurrence("overlaps-start", start: -10, end: 1),
            occurrence("seen", start: 2, end: 3),
            occurrence("inside", start: 3, end: 4),
            occurrence("overlaps-end", start: 9, end: 20),
            occurrence("starts-at-end", start: 10, end: 20),
            occurrence("after", start: 20, end: 30),
            occurrence("point-at-start", start: 0, end: 0),
            occurrence("point-at-end", start: 10, end: 10),
        ]
        var input = batch(source: .calendar, complete: true)
        input.occurrences = rows
        try await store.ingest(input)
        let window = DateInterval(start: epoch, duration: 10)
        try await store.reconcileOccurrences(source: .reminders, window: window, seen: [])
        try await store.reconcileOccurrences(source: .calendar, window: DateInterval(start: epoch, duration: 0), seen: [])
        let unchanged = try await store.occurrences(from: epoch.addingTimeInterval(-100), to: epoch.addingTimeInterval(100))
        XCTAssertEqual(Set(unchanged.map(\.id)), Set(rows.map(\.id)))
        try await store.reconcileOccurrences(source: .calendar, window: window, seen: [rows[3].id, "not-stored"])
        let kept = try await store.occurrences(from: epoch.addingTimeInterval(-100), to: epoch.addingTimeInterval(100))
        XCTAssertEqual(Set(kept.map(\.id)), Set([rows[0], rows[1], rows[3], rows[6], rows[7], rows[9]].map(\.id)))
        // A repeated reconciliation uses only its own seen set, including an empty complete scan.
        try await store.reconcileOccurrences(source: .calendar, window: window, seen: [])
        let later = try await store.occurrences(from: epoch.addingTimeInterval(-100), to: epoch.addingTimeInterval(100))
        XCTAssertEqual(Set(later.map(\.id)), Set([rows[0], rows[1], rows[6], rows[7], rows[9]].map(\.id)))
    }

    func testMovedOccurrenceKeepsOneRowWithTheNewTime() async throws {
        let store = try open()
        let original = occurrence("standup", start: 0, end: 900)
        let moved = occurrence("standup", start: 3600, end: 4500, capture: 60, original: 0)
        let nextDay = occurrence("standup", start: 86400, end: 87300)
        XCTAssertEqual(original.id, moved.id)
        XCTAssertNotEqual(original.id, nextDay.id)
        var first = batch(source: .calendar, complete: true)
        first.occurrences = [original, nextDay]
        try await store.ingest(first)
        var second = batch(source: .calendar, scan: 60, complete: true)
        second.occurrences = [moved]
        try await store.ingest(second)
        let stored = try await store.occurrences(from: epoch.addingTimeInterval(-100), to: epoch.addingTimeInterval(90000))
        XCTAssertEqual(stored.count, 2, "the moved occurrence replaces itself; the series isn't duplicated")
        XCTAssertEqual(stored.first { $0.id == moved.id }?.start, epoch.addingTimeInterval(3600))
    }

    func testOpenReminderReconciliationPreservesSeenCompletedAndOtherSources() async throws {
        let store = try open()
        let rows = [reminder("seen"), reminder("missing"), reminder("completed", completed: true, at: 1)]
        var input = batch(source: .reminders, complete: true)
        input.reminders = rows
        try await store.ingest(input)
        try await store.reconcileOpenReminders(source: .calendar, seen: [])
        let unchanged = try await store.reminders(from: epoch, to: epoch.addingTimeInterval(10))
        XCTAssertEqual(Set(unchanged.map(\.id)), Set(rows.map(\.id)))
        try await store.reconcileOpenReminders(source: .reminders, seen: [rows[0].id, "not-stored"])
        let kept = try await store.reminders(from: epoch, to: epoch.addingTimeInterval(10))
        XCTAssertEqual(Set(kept.map(\.id)), Set([rows[0].id, rows[2].id]))
    }

    func testScheduleReconciliationOnEmptyStoreIsNoOp() async throws {
        let store = try open()
        try await store.reconcileOccurrences(source: .calendar, window: DateInterval(start: epoch, duration: 10), seen: [])
        try await store.reconcileOpenReminders(source: .reminders, seen: [])
        let occurrences = try await store.occurrences(from: epoch, to: epoch.addingTimeInterval(10))
        let reminders = try await store.reminders(from: epoch, to: epoch.addingTimeInterval(10))
        let events = try await allEvents(store)
        let checkpoint = try await store.checkpoint(for: .calendar)
        XCTAssertTrue(occurrences.isEmpty)
        XCTAssertTrue(reminders.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(checkpoint)
    }

    func testScheduleReconciliationRollsBackOnFailure() async throws {
        let store = try open()
        var calendar = batch([event(0)], source: .calendar, complete: true)
        calendar.occurrences = [occurrence("first", start: 1, end: 2), occurrence("second", start: 3, end: 4)]
        var reminders = batch(source: .reminders, complete: true)
        reminders.reminders = [reminder("first"), reminder("second")]
        try await store.ingest(calendar)
        try await store.ingest(reminders)
        try await store.saveBrief(brief(0, citing: [event(0).id]))
        try await store.queue.write { db in
            // FAIL leaves the first deletion applied at statement level; the transaction must undo it.
            try db.execute(sql: """
            CREATE TEMP TRIGGER failOccurrence AFTER DELETE ON occurrence
            BEGIN SELECT RAISE(FAIL, 'synthetic failure'); END;
            CREATE TEMP TRIGGER failReminder AFTER DELETE ON reminder
            BEGIN SELECT RAISE(FAIL, 'synthetic failure'); END;
            """)
        }
        let window = DateInterval(start: epoch, duration: 10)
        do {
            try await store.reconcileOccurrences(source: .calendar, window: window, seen: [])
            XCTFail("expected occurrence deletion failure")
        } catch is DatabaseError {}
        do {
            try await store.reconcileOpenReminders(source: .reminders, seen: [])
            XCTFail("expected reminder deletion failure")
        } catch is DatabaseError {}
        let keptOccurrences = try await store.occurrences(from: window.start, to: window.end)
        let keptReminders = try await store.reminders(from: window.start, to: window.end)
        XCTAssertEqual(Set(keptOccurrences.map(\.id)), Set(calendar.occurrences.map(\.id)))
        XCTAssertEqual(Set(keptReminders.map(\.id)), Set(reminders.reminders.map(\.id)))
        try await store.queue.write { db in
            try db.execute(sql: "DROP TRIGGER failOccurrence; DROP TRIGGER failReminder")
        }
        try await store.reconcileOccurrences(source: .calendar, window: window, seen: [])
        try await store.reconcileOpenReminders(source: .reminders, seen: [])
        let clearedOccurrences = try await store.occurrences(from: window.start, to: window.end)
        let clearedReminders = try await store.reminders(from: window.start, to: window.end)
        let events = try await store.events(matching: "Synthetic message")
        let checkpoint = try await store.checkpoint(for: .calendar)
        let saved = try await store.latestBrief()
        XCTAssertTrue(clearedOccurrences.isEmpty)
        XCTAssertTrue(clearedReminders.isEmpty)
        XCTAssertEqual(events, calendar.events)
        XCTAssertEqual(checkpoint, calendar.checkpoint)
        XCTAssertEqual(saved, brief(0, citing: [event(0).id]))
    }

    func testOverlappingMidnightAllDayAndPointOccurrences() async throws {
        let store = try open()
        let rows = [
            occurrence("overnight", start: -3600, end: 3600),
            occurrence("all-day", start: 0, end: 86400, allDay: true),
            occurrence("ends-at-start", start: -3600, end: 0),
            occurrence("starts-at-end", start: 86400, end: 90000),
            occurrence("point", start: 0, end: 0),
        ]
        var input = batch(source: .calendar, complete: true)
        input.occurrences = rows
        try await store.ingest(input)
        let results = try await store.occurrences(from: epoch, to: epoch.addingTimeInterval(86400))
        XCTAssertEqual(Set(results.map(\.id)), Set([rows[0].id, rows[1].id, rows[4].id]))
        XCTAssertEqual(results.first?.id, rows[0].id)
        var partial = batch(source: .calendar, scan: 1)
        var edited = rows[0]
        edited.captureTime = epoch.addingTimeInterval(1)
        edited.title = "Synthetic edit"
        partial.occurrences = [edited]
        try await store.ingest(partial)
        var later = try await store.occurrences(from: epoch, to: epoch.addingTimeInterval(86400))
        XCTAssertEqual(later.count, 3)
        XCTAssertEqual(later.first?.title, "Synthetic edit")
        partial.checkpoint?.complete = true
        partial.checkpoint?.scannedAt = epoch.addingTimeInterval(2)
        try await store.ingest(partial)
        later = try await store.occurrences(from: epoch, to: epoch.addingTimeInterval(86400))
        XCTAssertEqual(later.count, 3)
        try await store.reconcileOccurrences(
            source: .calendar, window: DateInterval(start: epoch, duration: 86400), seen: [edited.id]
        )
        later = try await store.occurrences(from: epoch, to: epoch.addingTimeInterval(86400))
        XCTAssertEqual(later, [edited])
    }

    func testReminderCompletionWindowAndReconciliation() async throws {
        let store = try open()
        var open = reminder("open")
        open.due = .init(date: epoch.addingTimeInterval(-86400), hasTime: false, timeZone: "UTC")
        let rows = [
            open,
            reminder("no-due"),
            reminder("completed-at-start", completed: true, at: 0),
            reminder("completed-at-end", completed: true, at: 10),
            reminder("old", completed: true, at: -1),
            reminder("unknown-completion", completed: true),
        ]
        var input = batch(source: .reminders, complete: true)
        input.reminders = rows
        try await store.ingest(input)
        let results = try await store.reminders(from: epoch, to: epoch.addingTimeInterval(10))
        XCTAssertEqual(Set(results.map(\.id)), Set(rows.prefix(3).map(\.id)))
        var edited = open
        edited.isCompleted = true
        edited.completedAt = epoch.addingTimeInterval(1)
        edited.captureTime = epoch.addingTimeInterval(1)
        input.reminders = [edited]
        input.checkpoint?.scannedAt = epoch.addingTimeInterval(1)
        input.checkpoint?.complete = false
        try await store.ingest(input)
        var later = try await store.reminders(from: epoch.addingTimeInterval(2), to: epoch.addingTimeInterval(10))
        XCTAssertEqual(later.map(\.id), [rows[1].id])
        input.checkpoint?.complete = true
        input.checkpoint?.scannedAt = epoch.addingTimeInterval(2)
        try await store.ingest(input)
        later = try await store.reminders(from: epoch, to: epoch.addingTimeInterval(10))
        XCTAssertEqual(Set(later.map(\.id)), Set([edited.id, rows[1].id, rows[2].id]))
        try await store.reconcileOpenReminders(source: .reminders, seen: [])
        later = try await store.reminders(from: epoch, to: epoch.addingTimeInterval(10))
        XCTAssertEqual(Set(later.map(\.id)), Set([edited.id, rows[2].id]))
        let kept = try await store.queue.read { db in try String.fetchAll(db, sql: "SELECT id FROM reminder") }
        XCTAssertEqual(Set(kept), Set([edited.id] + rows.dropFirst(2).map(\.id)))
    }
}

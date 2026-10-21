@testable import AegisKit
import Foundation
import XCTest

@MainActor
final class AskTests: XCTestCase {
    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        result.firstWeekday = 2
        return result
    }

    func testTimePhrasesAndKeywords() throws {
        let now = try time("2026-10-07T15:00:00Z")
        let cases = [
            ("today", "2026-10-07T00:00:00Z", "2026-10-08T00:00:00Z"),
            ("this morning", "2026-10-07T00:00:00Z", "2026-10-07T12:00:00Z"),
            ("tonight", "2026-10-07T18:00:00Z", "2026-10-08T00:00:00Z"),
            ("yesterday", "2026-10-06T00:00:00Z", "2026-10-07T00:00:00Z"),
            ("tomorrow", "2026-10-08T00:00:00Z", "2026-10-09T00:00:00Z"),
            ("this week", "2026-10-05T00:00:00Z", "2026-10-12T00:00:00Z"),
            ("last week", "2026-09-28T00:00:00Z", "2026-10-05T00:00:00Z"),
            ("next week", "2026-10-12T00:00:00Z", "2026-10-19T00:00:00Z"),
            ("Monday", "2026-10-05T00:00:00Z", "2026-10-06T00:00:00Z"),
            ("when Monday", "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z"),
            ("last 3 days", "2026-10-04T15:00:00Z", "2026-10-07T15:00:00Z"),
        ]
        for (phrase, start, end) in cases {
            let query = AskQuery(phrase, now: now, calendar: calendar)
            XCTAssertEqual(query.messages.start, try time(start), phrase)
            XCTAssertEqual(query.messages.end, try time(end), phrase)
        }
        let query = AskQuery("What did they tell me about the INVOICE?", now: now, calendar: calendar)
        XCTAssertTrue(query.keywords.contains("invoice"))
        XCTAssertFalse(query.keywords.contains("what"))
        XCTAssertEqual(query.messages.start, try time("2026-09-30T15:00:00Z"))
        XCTAssertEqual(query.calendarWindow.end, try time("2026-10-14T15:00:00Z"))
    }

    func testPeopleUnionRankingAndQuotedContext() async throws {
        let now = try time("2026-10-07T15:00:00Z")
        let base = try XCTUnwrap(exampleEvents().first)
        let both = changed(base, "ask-both") {
            $0.senderHandle = "example@example.invalid"; $0.body = "Invoice approved"; $0.eventTime = now.addingTimeInterval(-300)
        }
        let keyword = changed(base, "ask-word") {
            $0.senderHandle = nil; $0.senderContact = nil; $0.body = "Invoice paid"; $0.eventTime = now.addingTimeInterval(-100)
        }
        let person = changed(both, "ask-person") { $0.body = "Lunch ready"; $0.eventTime = now.addingTimeInterval(-50) }
        let outside = changed(both, "ask-outside") { $0.eventTime = now.addingTimeInterval(-10 * 86400) }
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(
            source: .messages,
            status: .init(ok: true, code: .ok),
            events: [both, keyword, person, outside], checkpoint: nil
        ))
        let contacts = ContactIndex([.init(id: "example-contact", displayName: "Example Person", emails: ["example@example.invalid"])])
        for name in ["Example", "EXAMPLE PERSON"] {
            let input = try await Ask.prepare(
                question: "What did \(name) say about invoice?",
                now: now,
                calendar: calendar,
                store: store,
                contacts: contacts
            )
            XCTAssertEqual(input.eventIDs, [both.id, person.id])
            XCTAssertTrue(input.text.contains(jsonString("What did \(name) say about invoice?")))
            XCTAssertTrue(input.text.contains("[\(both.id)]"))
            XCTAssertFalse(input.text.contains(outside.id))
            XCTAssertTrue(input.text.contains("Example Person"))
        }
        let empty = try await Ask.prepare(question: "unfindable", now: now, calendar: calendar, store: store, contacts: nil)
        XCTAssertTrue(empty.isEmpty)
    }

    func testScheduleAndInputBudget() async throws {
        let now = try time("2026-10-07T15:00:00Z")
        let store = MemoryStore()
        let occurrence = CalendarOccurrence(
            itemID: "example-calendar",
            occurrenceDate: nil,
            calendarTitle: nil,
            title: "Example appointment",
            start: now,
            end: now.addingTimeInterval(3600),
            isAllDay: false,
            timeZone: nil,
            location: "Example room",
            status: .confirmed,
            captureTime: now, attendees: [.init(name: "Sam Sample", email: "sam@example.com", isOwner: false)]
        )
        let reminder = ReminderItem(
            itemID: "example-reminder",
            listTitle: nil,
            title: "Example task",
            due: .init(date: now, hasTime: true, timeZone: nil),
            isCompleted: false,
            completedAt: nil,
            priority: 0,
            captureTime: now
        )
        var outside = reminder
        outside.itemID = "example-outside"; outside.id = ScheduleID.reminder(itemID: outside.itemID)
        outside.due?.date = now.addingTimeInterval(20 * 86400)
        try await store.ingest(CollectionBatch(
            source: .calendar,
            status: .init(ok: true, code: .ok),
            events: [],
            occurrences: [occurrence],
            reminders: [reminder, outside], checkpoint: nil
        ))
        let input = try await Ask.prepare(question: "When are today's plans?", now: now, calendar: calendar, store: store, contacts: nil)
        XCTAssertEqual(Set(input.scheduleIDs), [occurrence.id, reminder.id])
        XCTAssertTrue(input.text.contains("Example room"))
        XCTAssertTrue(input.text.contains("Sam Sample"))
        XCTAssertTrue(input.text.contains("attendance unconfirmed"))
        XCTAssertFalse(input.text.contains(outside.id))
        XCTAssertLessThan(input.text.unicodeScalars.count, 8000)
        XCTAssertTrue(Ask.systemPrompt().contains("DATA"))
    }

    func testLowestRankedLinesDroppedAndCitationsStayExact() async throws {
        let now = try time("2026-10-07T15:00:00Z")
        let base = try XCTUnwrap(exampleEvents().first)
        let events = (0 ..< 30).map { index in
            changed(base, "example-budget-\(index)") {
                $0.sender = "Example sender"; $0.title = nil
                $0.body = "invoice " + String(repeating: "x", count: 500)
                $0.eventTime = now.addingTimeInterval(-Double(index + 1))
            }
        }
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
        let input = try await Ask.prepare(question: "invoice", now: now, calendar: calendar, store: store, contacts: nil)
        XCTAssertLessThan(input.text.unicodeScalars.count, 8000)
        XCTAssertLessThan(input.eventIDs.count, 25)
        XCTAssertEqual(input.eventIDs, Array(events.prefix(input.eventIDs.count)).map(\.id))
        for event in events {
            XCTAssertEqual(input.text.contains("[\(event.id)]"), input.eventIDs.contains(event.id))
        }
    }

    func testDraftChecks() throws {
        let ids = (0 ..< 11).map { EventID.make(source: .imessage, sourceRecordID: "example-\($0)") }
        let input = AskInput(text: "", eventIDs: ids, scheduleIDs: ["cal_example"])
        let now = Date(timeIntervalSince1970: 0)
        let valid: [String: Any] = ["answer": "Example answered you.", "event_ids": [ids[0], ids[0]], "schedule_ids": [String]()]
        func rejected(_ draft: [String: Any], _ expected: AskRejection) {
            switch Ask.check(draft, input: input, model: "example", generatedAt: now) {
            case let .failure(reason): XCTAssertEqual(reason, expected)
            case .success: XCTFail("Expected rejection")
            }
        }
        for field in ["answer", "event_ids", "schedule_ids"] {
            var draft = valid; draft[field] = 42; rejected(draft, .invalidDraft)
            draft = valid; draft.removeValue(forKey: field); rejected(draft, .invalidDraft)
        }
        var draft = valid; draft["action"] = "send"; rejected(draft, .invalidDraft)
        draft = valid; draft["event_ids"] = ["unknown"]; rejected(draft, .unknownCitation)
        draft = valid; draft["schedule_ids"] = ["unknown"]; rejected(draft, .unknownCitation)
        draft = valid; draft["answer"] = String(repeating: "x", count: Answer.maxTextScalars + 1); rejected(draft, .tooLong)
        draft = valid; draft["event_ids"] = [String](); rejected(draft, .unknownCitation)
        draft = valid; draft["event_ids"] = ids
        XCTAssertEqual(
            try Ask.check(draft, input: input, model: "example", generatedAt: now).get().eventIDs,
            Array(ids.prefix(10)),
            "a broad answer keeps its first ten citations"
        )
        draft = valid; draft["answer"] = "Alex asked in \(ids[1]) and \(ids[2])."; rejected(draft, .unsafeText)
        for text in ["sender_id=one said hello", "conversation=abc123", "bad\ttext", "bad\u{0}text", "one\ntwo\nthree\nfour"] {
            draft = valid; draft["answer"] = text; rejected(draft, .unsafeText)
        }
        let answer = try Ask.check(valid, input: input, model: "example", generatedAt: now).get()
        XCTAssertEqual(answer.eventIDs, [ids[0]])
        draft = valid; draft["answer"] = "I couldn't find it."; draft["event_ids"] = [String]()
        XCTAssertNoThrow(try Ask.check(draft, input: input, model: "example", generatedAt: now).get())
    }
}

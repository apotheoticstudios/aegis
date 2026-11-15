@testable import AegisKit
import Foundation
import XCTest

/// The owner's report (#203, second round): "Sweet. What have we got on today?" searched messages for "sweet" and
/// answered "I couldn't find anything about that". Everyday wording now reaches the calendar and the commands.
final class ChatUnderstandingTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return result
    }

    func testWhatPeopleSayAroundARequestIsNotTheRequest() {
        let cases = [
            ("Sweet. What have we got on today?", "What have we got on today?"),
            ("Friday, open Safari", "open Safari"),
            ("Hey Friday what's on tomorrow", "what's on tomorrow"),
            ("Okay so, run the Work shortcut", "run the Work shortcut"),
            ("Cool, thanks. What's the time?", "What's the time?"),
            ("so what did she want", "what did she want"),
            ("what's on tomorrow, mate?", "what's on tomorrow?"),
            ("Anyway, Friday, play some music", "play some music"),
        ]
        for (said, meant) in cases {
            XCTAssertEqual(Chat.request(said, name: "Friday"), meant, said)
        }
        for said in ["Yes, add it", "No, Example Dev", "Cool, thanks", "Sweet.", "Friday Dev shortcut", "and tomorrow?", "thanks"] {
            XCTAssertEqual(Chat.request(said, name: "Friday"), said, "left as said: \(said)")
        }
    }

    func testFillerIsNeverTheTopic() throws {
        let now = try time("2026-10-07T15:00:00Z")
        for phrase in ["Sweet. What have we got on today?", "What are we doing today, mate?", "Cool, what am I doing tomorrow?"] {
            let query = AskQuery(phrase, now: now, calendar: calendar)
            XCTAssertEqual(query.keywords, [], phrase)
            XCTAssertTrue(query.schedule, phrase)
        }
    }

    func testTheReportedQuestionReadsTodaysCalendar() async throws {
        let now = try time("2026-10-07T09:00:00Z")
        let store = MemoryStore()
        let base = try XCTUnwrap(exampleEvents().first)
        let chatter = changed(base, "sweet-chatter") { $0.body = "Sweet, see you then"; $0.eventTime = now.addingTimeInterval(-600) }
        try await store.ingest(CollectionBatch(
            source: .messages, status: .init(ok: true, code: .ok), events: [chatter], checkpoint: nil
        ))
        let standup = CalendarOccurrence(
            itemID: "example-standup", occurrenceDate: nil, calendarTitle: nil, title: "Example standup",
            start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), isAllDay: false, timeZone: nil, location: nil,
            status: .confirmed, captureTime: now, attendees: []
        )
        try await store.ingest(CollectionBatch(
            source: .calendar, status: .init(ok: true, code: .ok), events: [], occurrences: [standup], reminders: [], checkpoint: nil
        ))
        let input = try await Ask.prepare(
            question: "Sweet. What have we got on today?", now: now, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(input.scheduleIDs.count, 1, "today's plan")
        XCTAssertEqual(input.eventIDs, [], "a message that says “sweet” isn't what was asked about")
    }

    func testEverydayCommandsReachTheModel() {
        for line in [
            "fire up Spotify",
            "make it louder",
            "I want to listen to some music",
            "let's play some jazz",
            "get me to the airport",
        ] {
            XCTAssertTrue(CommandPlan.looksLikeCommand(line), line)
        }
        for line in ["what's on today", "who texted me", "how do I make pancakes"] {
            XCTAssertFalse(CommandPlan.looksLikeCommand(line), line)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ActionCommand.parse("go ahead and open Safari", now: now, calendar: calendar), .openApp(name: "Safari"))
        XCTAssertEqual(ActionCommand.parse("I need you to open Safari", now: now, calendar: calendar), .openApp(name: "Safari"))
    }
}

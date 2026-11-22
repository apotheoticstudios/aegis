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
        for said in [
            "Yes, add it", "No, Example Dev", "Cool, thanks", "Sweet.", "Friday Dev shortcut", "and tomorrow?", "thanks",
            "run Backup Friday", "Ask Claude to explain the money I lent to Friday", "Remember that my assistant is Friday",
        ] {
            XCTAssertEqual(Chat.request(said, name: "Friday"), said, "left as said: \(said)")
        }
    }

    func testFillerIsNeverTheTopic() throws {
        let now = try time("2026-10-07T15:00:00Z")
        for phrase in ["What have we got on today?", "What are we doing today, mate?", "what am I doing tomorrow, guys?"] {
            let query = AskQuery(phrase, now: now, calendar: calendar)
            XCTAssertEqual(query.keywords, [], phrase)
            XCTAssertTrue(query.schedule, phrase)
        }
        XCTAssertEqual(AskQuery("Read my messages about Nice", now: now, calendar: calendar).keywords, ["read", "messages", "nice"])
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
        // As the panel asks it: without the lead-in.
        let input = try await Ask.prepare(
            question: Chat.request("Sweet. What have we got on today?", name: "Friday"), now: now, calendar: calendar, store: store,
            contacts: nil
        )
        XCTAssertEqual(input.scheduleIDs.count, 1, "today's plan")
        XCTAssertEqual(input.eventIDs, [], "a message that says “sweet” isn't what was asked about")
    }

    /// #209: "What have I got on today?" got the couldn't-find line although the model answered from today's calendar.
    /// It had filed the calendar citations under event_ids, as the real local model does with several events.
    func testCalendarCitationsCountWhereverTheModelFilesThem() async throws {
        let now = try time("2026-10-07T09:00:00Z")
        let store = MemoryStore()
        let items = ["Example standup", "Lunch with Example Sam"].enumerated().map { index, title in
            CalendarOccurrence(
                itemID: "example-\(index)", occurrenceDate: nil, calendarTitle: nil, title: title,
                start: now.addingTimeInterval(Double(index + 1) * 3600), end: now.addingTimeInterval(Double(index + 2) * 3600),
                isAllDay: false, timeZone: nil, location: nil, status: .confirmed, captureTime: now, attendees: []
            )
        }
        try await store.ingest(CollectionBatch(
            source: .calendar, status: .init(ok: true, code: .ok), events: [], occurrences: items, reminders: [], checkpoint: nil
        ))
        let input = try await Ask.prepare(question: "What have I got on today?", now: now, calendar: calendar, store: store, contacts: nil)
        XCTAssertEqual(input.scheduleIDs.count, 2)
        let said = "You have Example standup at 10am and Lunch with Example Sam at 11am."
        let misfiled: [String: Any] = ["answer": said, "event_ids": input.scheduleIDs, "schedule_ids": [String]()]
        let answer = try Ask.check(misfiled, input: input, model: "example", generatedAt: now).get()
        XCTAssertEqual(answer.text, said)
        XCTAssertEqual(answer.scheduleIDs, input.scheduleIDs)
        XCTAssertEqual(answer.eventIDs, [])
        let swapped: [String: Any] = ["answer": said, "event_ids": [String](), "schedule_ids": input.scheduleIDs]
        XCTAssertEqual(try Ask.check(swapped, input: input, model: "example", generatedAt: now).get().scheduleIDs, input.scheduleIDs)
        // Its own list's order comes first: a repeat filed under the other list never pushes out the model's first choice.
        let messages = (0 ..< Answer.maxCitations - 1).map { "ev_\($0)" }
        let crowded = AskInput(text: "", eventIDs: messages, scheduleIDs: ["cal_a", "cal_b"])
        let mixed: [String: Any] = ["answer": said, "event_ids": messages + ["cal_b"], "schedule_ids": ["cal_a", "cal_b"]]
        let kept = try Ask.check(mixed, input: crowded, model: "example", generatedAt: now).get()
        XCTAssertEqual(kept.eventIDs, messages)
        XCTAssertEqual(kept.scheduleIDs, ["cal_a"])
        // An ID that isn't in this question's context still backs nothing.
        let invented: [String: Any] = ["answer": said, "event_ids": ["cal_0123456789abcdef"], "schedule_ids": [String]()]
        XCTAssertEqual(try Ask.check(invented, input: input, model: "example", generatedAt: now).get().text, Ask.notFound)
    }

    func testEverydayCommandsReachTheModel() {
        for line in [
            "fire up Spotify",
            "make it louder",
            "I want to listen to some music",
            "let's play some jazz",
            "crank it up",
        ] {
            XCTAssertTrue(CommandPlan.looksLikeCommand(line), line)
        }
        for line in ["what's on today", "who texted me", "how do I make pancakes", "show my calendar", "find messages about the dentist"] {
            XCTAssertFalse(CommandPlan.looksLikeCommand(line), line)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ActionCommand.parse("go ahead and open Safari", now: now, calendar: calendar), .openApp(name: "Safari"))
        XCTAssertEqual(ActionCommand.parse("I need you to open Safari", now: now, calendar: calendar), .openApp(name: "Safari"))
    }
}

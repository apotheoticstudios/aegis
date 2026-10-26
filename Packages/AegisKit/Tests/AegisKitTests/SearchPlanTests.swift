@testable import AegisKit
import Foundation
import XCTest

/// The model's search plan (ADR-0032): every field checked, and the search it shapes. Synthetic text only.
final class SearchPlanTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        result.firstWeekday = 2
        return result
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-07T15:00:00Z")! // a Wednesday

    func testParsesAndChecksEveryField() throws {
        let question = "What did Sam Example say about the parcel this week?"
        let reply = """
        Here you go:
        ```json
        {"lookup":true,"look_in":["Messages","mail","fax"],"when":"This  Week","people":["Sam Example","Robin"],
         "topics":["parcel","messages","delivery"],"direction":"received"}
        ```
        """
        let plan = try XCTUnwrap(SearchPlan.parse(reply, question: question))
        XCTAssertTrue(plan.lookup)
        XCTAssertEqual(plan.places, [.messages, .mail], "unknown places are dropped")
        XCTAssertEqual(plan.when, "this week")
        XCTAssertEqual(plan.people, ["Sam Example"], "a name the owner didn't write is dropped")
        XCTAssertEqual(plan.topics, ["parcel", "delivery"], "place words aren't topics")
        XCTAssertEqual(plan.direction, .incoming)

        let general = try XCTUnwrap(SearchPlan.parse(#"{"lookup":false}"#, question: "Tell me a joke"))
        XCTAssertFalse(general.lookup)
        XCTAssertNil(SearchPlan.parse(#"{"look_in":["calendar"]}"#, question: "x"), "no lookup, no plan")
        XCTAssertNil(SearchPlan.parse("I think you mean your calendar.", question: "x"))

        let open = try XCTUnwrap(SearchPlan.parse(#"{"lookup":true,"look_in":[],"when":null}"#, question: "x"))
        XCTAssertEqual(open.places, Set(SearchPlan.Place.allCases), "nowhere named: everywhere")
        XCTAssertNil(open.when)
        for kept in ["the next 7 days", "the last 30 days", "next monday", "thursday", "last sunday", "this weekend", "tonight"] {
            XCTAssertEqual(SearchPlan.parse(#"{"lookup":true,"when":""# + kept + #""}"#, question: "x")?.when, kept, kept)
        }
        for refused in ["sometime soon", "2026-10-09", "next 7 days", "the next 9999 days", "friday at 3pm"] {
            XCTAssertNil(SearchPlan.parse(#"{"lookup":true,"when":""# + refused + #""}"#, question: "x")?.when, refused)
        }
        XCTAssertEqual(SearchPlan.parse(#"{"lookup":true,"direction":"sent"}"#, question: "x")?.direction, .outgoing)
    }

    func testTheModelSeesOnlyTheOwnersWordsAndToday() {
        let input = SearchPlan.input(question: "What have I got on next Friday?", now: now, calendar: calendar)
        XCTAssertEqual(input, "TODAY: Wednesday 7 October 2026, 3:00 PM\nOWNER ASKS: What have I got on next Friday?")
        XCTAssertTrue(SearchPlan.systemPrompt().contains("ONLY JSON"))
    }

    /// The model names the time; the dates are exact, from code.
    func testTheTimeBecomesExactDates() throws {
        func window(_ when: String) throws -> DateInterval {
            try XCTUnwrap(SearchPlan(lookup: true, places: [.calendar], when: when).window(now: now, calendar: calendar))
        }
        let day = { (offset: Double) in self.calendar.startOfDay(for: self.now).addingTimeInterval(offset * 86400) }
        // Used loosely for each other, so both run from now to the end of next week.
        XCTAssertEqual(try window("the next 7 days"), DateInterval(start: now, end: day(12)))
        XCTAssertEqual(try window("next week"), DateInterval(start: now, end: day(12)))
        XCTAssertEqual(try window("the next 3 days"), DateInterval(start: now, end: now.addingTimeInterval(3 * 86400)))
        XCTAssertEqual(try window("tomorrow"), DateInterval(start: day(1), end: day(2)))
        XCTAssertEqual(try window("next monday"), DateInterval(start: day(5), end: day(6)))
        XCTAssertEqual(try window("thursday"), DateInterval(start: day(1), end: day(2)))
        XCTAssertEqual(try window("last monday"), DateInterval(start: day(-2), end: day(-1)))
        XCTAssertEqual(try window("this weekend"), DateInterval(start: day(3), end: day(5)))
        XCTAssertEqual(try window("last week"), DateInterval(start: day(-9), end: now), "from the start of last week to now")
        let replied = try XCTUnwrap(SearchPlan(lookup: true, places: [.messages], when: "monday").window(now: now, calendar: calendar))
        XCTAssertEqual(replied, DateInterval(start: day(-2), end: day(-1)), "messages are in the past: the Monday just gone")
        XCTAssertNil(SearchPlan(lookup: true, places: [], when: nil).window(now: now, calendar: calendar))
    }

    func testAPlanShapesTheSearch() async throws {
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(
            source: .calendar, status: .init(ok: true, code: .ok), events: [],
            occurrences: [occurrence("plan-soon", "Example lunch", days: 2), occurrence("plan-later", "Dentist check-up", days: 60)],
            reminders: [], checkpoint: nil
        ))
        func prepare(_ plan: SearchPlan, _ question: String = "Anything?") async throws -> AskInput {
            try await Ask.prepare(question: question, now: now, calendar: calendar, store: store, contacts: nil, plan: plan)
        }
        let week = try await prepare(SearchPlan(lookup: true, places: [.calendar], when: "the next 7 days"), "What's happening?")
        XCTAssertEqual(week.scheduleIDs, [occurrence("plan-soon", "Example lunch", days: 2).id])
        XCTAssertNil(week.directAnswer)

        // About a topic with no time named: months ahead, matched by the topic.
        let dentist = try await prepare(SearchPlan(lookup: true, places: [.calendar], when: nil, topics: ["dentist"]))
        XCTAssertEqual(dentist.scheduleIDs, [occurrence("plan-later", "Dentist check-up", days: 60).id])

        let messagesOnly = try await prepare(SearchPlan(lookup: true, places: [.messages], when: "the next 7 days"))
        XCTAssertTrue(messagesOnly.scheduleIDs.isEmpty, "the calendar isn't read when the plan doesn't ask for it")

        let nothing = try await prepare(SearchPlan(lookup: true, places: [.calendar], when: "the last 3 days"))
        XCTAssertEqual(nothing.directAnswer, "There's nothing in your calendar or reminders for that time.")

        let general = try await prepare(SearchPlan(lookup: false, places: [], when: nil), "Give me a pasta recipe")
        XCTAssertTrue(general.isEmpty)
        XCTAssertNil(general.directAnswer, "general questions go to the conversation")
    }

    /// The engine asks the model for a plan first, then searches by it: the owner's question from 2026-10-26, worded
    /// so no phrase rule would catch it.
    func testTheEngineSearchesByTheModelsPlan() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MemoryStore()
        let lunch = occurrence("plan-soon", "Example lunch", days: 2)
        try await store.ingest(CollectionBatch(
            source: .calendar, status: .init(ok: true, code: .ok), events: [], occurrences: [lunch], reminders: [], checkpoint: nil
        ))
        let model = PlanningModel()
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone),
            options: .init(modelName: "synthetic-model"), clock: { [now] in now }
        )
        guard case let .answer(answer) = await core.handle(.ask(question: "Am I swamped over the coming seven days?")) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer.scheduleIDs, [lunch.id])
        XCTAssertEqual(model.kinds, ["plan", "ask"])
    }

    private func occurrence(_ item: String, _ title: String, days: Double) -> CalendarOccurrence {
        CalendarOccurrence(
            itemID: item, occurrenceDate: nil, calendarTitle: nil, title: title, start: now.addingTimeInterval(days * 86400),
            end: now.addingTimeInterval(days * 86400 + 3600), isAllDay: false, timeZone: nil, location: nil, status: .confirmed,
            captureTime: now, attendees: []
        )
    }
}

/// Plans a calendar search for the next seven days, then answers citing the first calendar line it was given.
private final class PlanningModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var kinds: [String] {
        lock.withLock { seen }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        let kind = String(job.id.prefix { $0 != "-" })
        lock.withLock { seen.append(kind) }
        if kind == "plan" {
            return ModelJobResult(
                jobID: job.id,
                status: .completed,
                text: #"{"lookup":true,"look_in":["calendar"],"when":"the next 7 days"}"#
            )
        }
        let cited = job.user.range(of: #"(?m)^\[([^\]]+)\]"#, options: .regularExpression)
            .map { String(job.user[$0].dropFirst().dropLast()) } ?? ""
        let answer = #"{"answer":"Just Example lunch.","event_ids":[],"schedule_ids":[""# + cited + #""]}"#
        return ModelJobResult(jobID: job.id, status: .completed, text: answer)
    }

    func cancel(jobID _: String) async {}
}

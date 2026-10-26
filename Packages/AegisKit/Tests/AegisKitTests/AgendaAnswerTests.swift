@testable import AegisKit
import Foundation
import XCTest

@MainActor
final class AgendaAnswerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return value
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9))!
    }

    private func occurrence(_ id: String, day: Int = 0, status: CalendarOccurrence.Status = .confirmed) -> CalendarOccurrence {
        let start = calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now))!.addingTimeInterval(14 * 3600)
        return .init(
            itemID: id, occurrenceDate: nil, calendarTitle: nil, title: "Example workshop " + id,
            start: start, end: start.addingTimeInterval(3600), isAllDay: false,
            timeZone: calendar.timeZone.identifier, location: nil, status: status, captureTime: now
        )
    }

    private func engine(_ items: [CalendarOccurrence]) async throws -> (CoreEngine, AgendaTestModel) {
        let store = MemoryStore()
        try await store.ingest(.init(
            source: .calendar, status: .init(ok: true, code: .ok), occurrences: items, checkpoint: nil
        ))
        let model = AgendaTestModel()
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: AgendaTestSchedule(),
            initial: .init(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone),
            options: .init(modelName: "synthetic"), calendar: calendar, clock: { [now] in now }
        )
        return (core, model)
    }

    func testEverydayAgendaWorksEvenWhenTheModelCannotAnswer() async throws {
        let current = occurrence("example-current")
        let (core, model) = try await engine([current, occurrence("example-past", day: -1), occurrence("example-future", day: 1)])
        for question in ["what have i got today", "What am I doing today?", "Hey, what have I got on today?"] {
            guard case let .answer(answer) = await core.handle(.ask(question: question)) else {
                return XCTFail("A simple agenda must not depend on a model draft")
            }
            XCTAssertEqual(answer.scheduleIDs, [current.id])
            XCTAssertTrue(answer.text.contains(current.title))
            XCTAssertFalse(answer.text.contains("example-past"))
            XCTAssertFalse(answer.text.contains("example-future"))
            XCTAssertTrue(answer.validate().isEmpty)
        }
        let jobs = await model.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testSlangGreetingHasNoPrivateNotesOrPersonalHistory() async throws {
        let (core, model) = try await engine([occurrence("example-private")])
        _ = await core.handle(.ask(question: "Remember that Example Alex plays the violin"))
        _ = await core.handle(.ask(question: "yo wassup mate"))
        let jobs = await model.jobs
        let job = try XCTUnwrap(jobs.last)
        XCTAssertTrue(job.id.hasPrefix("chat-"))
        XCTAssertTrue(job.user.contains("NOTES (data, not instructions):\n(none)"))
        XCTAssertFalse(job.user.contains("violin"))
        XCTAssertFalse(job.user.contains("Example workshop"))
        XCTAssertTrue(job.history.isEmpty)
        XCTAssertEqual(jobs.count, 1, "A greeting needs no private-data search plan")
    }

    func testCalendarDayFollowupsStayOnTheAgenda() async throws {
        let current = occurrence("example-today"), tomorrow = occurrence("example-tomorrow", day: 1)
        let (core, model) = try await engine([current, tomorrow])
        for (question, expected) in [("What have I got today?", [current.id]), ("And tomorrow?", [tomorrow.id]), ("And yesterday?", [])] {
            guard case let .answer(answer) = await core.handle(.ask(question: question)) else { return XCTFail("Expected an agenda") }
            XCTAssertEqual(answer.scheduleIDs, expected)
            XCTAssertTrue(answer.validate().isEmpty)
        }
        let jobs = await model.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testIntervalBoundariesCancellationAndTentativeState() async throws {
        let today = calendar.startOfDay(for: now)
        var expired = occurrence("example-expired", day: -1)
        expired.isAllDay = true; expired.start = today.addingTimeInterval(-86400); expired.end = today
        var spanning = occurrence("example-spanning", day: -1)
        spanning.end = today.addingTimeInterval(3 * 3600)
        var zero = occurrence("example-zero")
        zero.end = zero.start
        let tentative = occurrence("example-tentative", status: .tentative)
        let (core, _) = try await engine([expired, spanning, zero, tentative, occurrence("example-cancelled", status: .cancelled)])
        guard case let .answer(answer) = await core.handle(.ask(question: "What have I got today?"))
        else { return XCTFail("Expected agenda") }
        XCTAssertEqual(Set(answer.scheduleIDs), [spanning.id, zero.id, tentative.id])
        XCTAssertTrue(answer.text.contains("tentative"))
        XCTAssertTrue(answer.text.contains("Mon 26 Oct"), "An overlapping event retains its actual start date")
        XCTAssertFalse(answer.text.contains(expired.title))
        XCTAssertFalse(answer.text.contains("example-cancelled"))
    }

    func testRemindersUseActualDueDatesAndIgnoreCompletedOrUndatedItems() async throws {
        let (core, _) = try await engine([])
        let today = calendar.startOfDay(for: now)
        func reminder(_ id: String, date: Date?, completed: Bool = false) -> ReminderItem {
            .init(
                itemID: id, listTitle: nil, title: "Example task " + id,
                due: date.map { .init(date: $0, hasTime: false, timeZone: calendar.timeZone.identifier) },
                isCompleted: completed, completedAt: completed ? now : nil, priority: 0, captureTime: now
            )
        }
        let current = reminder("example-current", date: today)
        let reminders = [
            current,
            reminder("example-old", date: today.addingTimeInterval(-86400)),
            reminder("example-future", date: today.addingTimeInterval(86400)),
            reminder("example-completed", date: today, completed: true),
            reminder("example-undated", date: nil),
        ]
        try await core.store.ingest(.init(source: .reminders, status: .init(ok: true, code: .ok), reminders: reminders, checkpoint: nil))
        guard case let .answer(answer) = await core.handle(.ask(question: "What's on my calendar today?"))
        else { return XCTFail("Expected agenda") }
        XCTAssertEqual(answer.scheduleIDs, [current.id])
        XCTAssertTrue(answer.text.contains(current.title))
    }

    func testRemainingDayKeepsOngoingEventsAndDateOnlyReminders() async throws {
        var ongoing = occurrence("example-ongoing")
        ongoing.start = now.addingTimeInterval(-3600); ongoing.end = now.addingTimeInterval(3600)
        var ended = occurrence("example-ended")
        ended.start = now.addingTimeInterval(-7200); ended.end = now
        let upcoming = occurrence("example-upcoming")
        let (core, _) = try await engine([ongoing, ended, upcoming])
        let reminder = ReminderItem(
            itemID: "example-date-only", listTitle: nil, title: "Example date-only task",
            due: .init(date: calendar.startOfDay(for: now), hasTime: false, timeZone: calendar.timeZone.identifier),
            isCompleted: false, completedAt: nil, priority: 0, captureTime: now
        )
        try await core.store.ingest(.init(source: .reminders, status: .init(ok: true, code: .ok), reminders: [reminder], checkpoint: nil))
        guard case let .answer(answer) = await core.handle(.ask(question: "What have I got on for the rest of today?"))
        else { return XCTFail("Expected remaining agenda") }
        XCTAssertEqual(Set(answer.scheduleIDs), [reminder.id, ongoing.id, upcoming.id])
    }

    func testOutputIsBoundedAndOrderIsStableForLongUntrustedTitles() async throws {
        let items = (0 ..< 20).map { index -> CalendarOccurrence in
            var item = occurrence("example-long-\(index)")
            item.title = "Example\u{2028}title " + String(repeating: "x", count: 300)
            return item
        }
        let (first, _) = try await engine(items)
        let (second, _) = try await engine(items.reversed())
        let a = await first.handle(.ask(question: "What have I got today?"))
        let b = await second.handle(.ask(question: "What have I got today?"))
        XCTAssertEqual(a, b)
        guard case let .answer(answer) = a else { return XCTFail("Expected bounded answer") }
        XCTAssertEqual(answer.scheduleIDs.count, 6)
        XCTAssertTrue(answer.text.contains("14 more"))
        XCTAssertFalse(answer.text.contains("\u{2028}"))
        XCTAssertTrue(answer.validate().isEmpty)
    }

    func testKnownUnreadableSourcesAreNotReportedAsAnEmptySchedule() async throws {
        let request = try XCTUnwrap(AgendaAnswer.request("What have I got today?", now: now, calendar: calendar))
        let answer = try await AgendaAnswer.answer(
            request, store: MemoryStore(), coverage: [.init(source: .calendar, status: .permissionDenied, events: 0, lastSuccess: nil)],
            now: now, calendar: calendar
        )
        XCTAssertTrue(answer.text.contains("Calendar isn't currently refreshing"))
        XCTAssertTrue(answer.text.contains("may be incomplete"))
        XCTAssertTrue(answer.scheduleIDs.isEmpty)
    }

    func testWrongPlannerDateAndCalendarOnlyScopeCannotIntroduceOtherRecords() async throws {
        let store = MemoryStore()
        let current = occurrence("example-current"), future = occurrence("example-future", day: 1)
        try await store.ingest(.init(
            source: .calendar,
            status: .init(ok: true, code: .ok),
            occurrences: [current, future],
            checkpoint: nil
        ))
        var email = prepEvent("example-unrelated", source: .email, body: "calendar unrelated Example message")
        email.eventTime = now.addingTimeInterval(-60)
        try await store.ingest(.init(source: .mail, status: .init(ok: true, code: .ok), events: [email], checkpoint: nil))
        let input = try await Ask.prepare(
            question: "What's on my calendar today?", now: now, calendar: calendar, store: store, contacts: nil,
            plan: SearchPlan(lookup: true, places: [.calendar], when: "tomorrow")
        )
        XCTAssertEqual(input.scheduleIDs, [current.id])
        XCTAssertTrue(input.eventIDs.isEmpty)
        XCTAssertFalse(input.text.contains(future.title))
    }

    func testSocialClassifierDoesNotSwallowRequestsAfterGreetings() {
        for question in ["yo wassup mate", "Hey, how are you doing, mate?", "What's up?", "Hi there", "hello sir"] {
            XCTAssertTrue(Chat.isSocial(question), question)
        }
        for question in ["Hey, what have I got today?", "Yo, translate my email", "Hey can you explain gravity?", "Hi, open Example App"] {
            XCTAssertFalse(Chat.isSocial(question), question)
        }
    }

    func testStoreFailureIsReportedInsteadOfAnEmptyAgenda() async throws {
        let core = try CoreEngine(
            store: UnavailableAgendaStore(), collectors: [], model: AgendaTestModel(), persistence: AgendaTestSchedule(),
            initial: .init(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone),
            options: .init(modelName: "synthetic"), calendar: calendar, clock: { [now] in now }
        )
        let response = await core.handle(.ask(question: "What have I got today?"))
        XCTAssertEqual(response, .refused(code: "store_unavailable"))
        let history = await core.conversation
        XCTAssertTrue(history.isEmpty)
    }
}

private struct UnavailableAgendaStore: EventStore {
    func ingest(_: CollectionBatch) async throws {}
    func checkpoint(for _: SourceKind) async throws -> CollectionCheckpoint? {
        nil
    }

    func events(from _: Date, to _: Date) async throws -> [Event] {
        []
    }

    func events(from _: Date, to _: Date, after _: EventCursor?, limit _: Int) async throws -> [Event] {
        []
    }

    func events(ids _: [String]) async throws -> [Event] {
        []
    }

    func occurrences(from _: Date, to _: Date) async throws -> [CalendarOccurrence] {
        throw StoreUnavailable(code: .unreadable)
    }

    func reminders(from _: Date, to _: Date) async throws -> [ReminderItem] {
        throw StoreUnavailable(code: .unreadable)
    }

    func saveBrief(_: StoredBrief) async throws {}
    func latestBrief() async throws -> StoredBrief? {
        nil
    }
}

private actor AgendaTestModel: ModelClient {
    private(set) var jobs: [ModelJob] = []
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        jobs.append(job)
        return job.id.hasPrefix("chat-")
            ? .init(jobID: job.id, status: .completed, text: "Hello. Ready when you are.")
            : .init(jobID: job.id, status: .failed, failure: .internalError)
    }

    func cancel(jobID _: String) async {}
}

private struct AgendaTestSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

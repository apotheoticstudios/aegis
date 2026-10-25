@testable import AegisKit
import Foundation
import XCTest

/// Synthetic reproductions of date drift, translation clarifications and accidental memory writes (#36).
@MainActor
final class ConversationAccuracyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return value
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
    }

    private func message(_ id: String, _ body: String, days: Int = -1, sender: String = "Example Store") -> Event {
        Event(
            source: .sms, sourceRecordID: id, appID: nil, sender: sender, threadID: "example-thread-" + id,
            eventTime: now.addingTimeInterval(Double(days) * 86400), eventTimeSource: .sent, captureTime: now,
            title: nil, body: body, content: .complete,
            observations: [.init(route: .chatDB, sourceRecordID: id, captureTime: now)], direction: .incoming, senderHandle: "0400000001"
        )
    }

    private func setup(_ events: [Event] = [], occurrences: [CalendarOccurrence] = []) async throws -> (CoreEngine, AccuracyModel) {
        let store = MemoryStore()
        try await store.ingest(.init(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
        try await store.ingest(.init(
            source: .calendar, status: .init(ok: true, code: .ok), events: [], occurrences: occurrences, checkpoint: nil
        ))
        let model = AccuracyModel(eventID: events.first?.id, scheduleID: occurrences.first?.id)
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: AccuracySchedule(),
            initial: .init(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone),
            options: .init(modelName: "synthetic-model"), calendar: calendar, clock: { [now] in now }
        )
        return (core, model)
    }

    func testChineseIsTheMessageLanguageRatherThanASenderOrSearchKeyword() async throws {
        let target = message("example-chinese", "您的包裹已经到达。")
        var outgoing = message("example-outgoing", "谢谢。")
        outgoing.direction = .outgoing; outgoing.sender = "me"
        var email = message("example-email", "您的包裹已经到达。")
        email.source = .email
        email.id = EventID.make(source: .email, sourceRecordID: email.sourceRecordID)
        email.observations = [.init(route: .mailStore, sourceRecordID: email.sourceRecordID, captureTime: now)]
        let store = MemoryStore()
        let events = [
            target,
            outgoing,
            email,
            message("example-english", "Your parcel has arrived.", sender: "Chinese"),
            message("example-old", "您的包裹已经到达。", days: -3),
        ]
        try await store.ingest(.init(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
        let question = "Translate the text message I got from Chinese to English yesterday."
        let input = try await Ask.prepare(question: question, now: now, calendar: calendar, store: store, contacts: nil)
        XCTAssertEqual(input.eventIDs, [target.id])
        XCTAssertNil(input.directAnswer)
        XCTAssertTrue(input.text.contains(target.body))
        let compound = try await Ask.prepare(
            question: "That was yesterday. Also, what was that text message I got in Chinese? Can you translate it?",
            now: now, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(compound.eventIDs, [target.id], "A correction followed by a new request is not a literal keyword search for 'also'")
        let selection = AskSelection(question, query: AskQuery(question, now: now, calendar: calendar))
        XCTAssertNil(selection.sender)
        XCTAssertTrue(selection.terms.isEmpty)
        let reverse = AskSelection("Translate my message from English to Chinese", query: AskQuery("", now: now, calendar: calendar))
        XCTAssertTrue(
            reverse.matches(message("example-english-target", "Hello from Example Store")),
            "Target language is not the source language"
        )
        for language in ["French", "Japanese", "Arabic", "Spanish"] {
            let request = "Translate the text message I got from \(language) to English"
            let picked = AskSelection(request, query: AskQuery(request, now: now, calendar: calendar))
            XCTAssertNil(picked.sender, "\(language) describes the source language")
            XCTAssertTrue(picked.terms.isEmpty)
        }
    }

    func testNoResultThenSenderAndTimeClarificationResumesTranslationWithoutSavingAFact() async throws {
        let target = message("example-target", "您的包裹已经到达。")
        let other = message("example-other", "明天见。", sender: "Example Other")
        let (core, model) = try await setup([target, other])
        let question = "Translate the Chinese text message I received today into English."
        guard case let .answer(missing) = await core.handle(.ask(question: question)) else { return XCTFail("Expected a local answer") }
        XCTAssertTrue(missing.text.contains("couldn't find"))
        let initialJobs = await model.jobs
        XCTAssertTrue(initialJobs.isEmpty)
        guard case let .answer(translated) = await core.handle(.ask(question: "It was yesterday. From Example Store.")) else {
            return XCTFail("A clarification must resume the translation")
        }
        XCTAssertEqual(translated.eventIDs, [target.id])
        let jobs = await model.jobs
        let job = try XCTUnwrap(jobs.last)
        XCTAssertTrue(job.id.hasPrefix("ask-"))
        XCTAssertTrue(job.user.contains("Translate") && job.user.contains("English"))
        XCTAssertTrue(job.user.contains("[" + target.id + "]"))
        XCTAssertFalse(job.user.contains("[" + other.id + "]"))
        XCTAssertFalse(job.user.contains("today into English"), "The newer date replaces the old date")
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected memory list") }
        XCTAssertTrue(notes.isEmpty)
    }

    func testAnUnrelatedQuestionDoesNotResumeTheFailedTranslation() async throws {
        let (core, model) = try await setup()
        _ = await core.handle(.ask(question: "Translate my Chinese text message today into English"))
        _ = await core.handle(.ask(question: "Explain why leaves change colour"))
        let jobs = await model.jobs
        let job = try XCTUnwrap(jobs.last)
        XCTAssertTrue(job.id.hasPrefix("chat-"))
        XCTAssertFalse(job.user.contains("Translate"))
        XCTAssertFalse(job.user.contains("From Example Store"))
        XCTAssertNil(FollowUpQuestion.clarification(
            "It was yesterday. Also, explain gravity", after: "Translate the Chinese message today", now: now, calendar: calendar
        ))
        XCTAssertNil(FollowUpQuestion.clarification(
            "Translate the message from Example Other today", after: "Translate the message from Example Store yesterday",
            now: now, calendar: calendar
        ))
    }

    func testNegatedRememberRemovesTheNoteAndDoesNotAskTheModel() async throws {
        let (core, model) = try await setup()
        _ = await core.handle(.ask(question: "Remember that my favourite colour is blue"))
        guard case let .answer(forgot) = await core.handle(.ask(question: "Don't remember that."))
        else { return XCTFail("Expected acknowledgement") }
        XCTAssertTrue(forgot.text.contains("forgotten"))
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected memories") }
        XCTAssertTrue(notes.isEmpty)
        let jobs = await model.jobs
        XCTAssertTrue(jobs.isEmpty, "Memory controls are deterministic")
        let exchanges = await core.memory.exchanges
        XCTAssertFalse(exchanges.contains { $0.owner.contains("favourite colour") })
        for text in ["It was yesterday. From Example Store.", "That was yesterday", "It is from Example Store"] {
            XCTAssertNil(MemoryCommand.statedFact(text))
        }
    }

    func testDoNotRememberAClarificationDoesNotDeleteAnUnrelatedNote() async throws {
        let (core, _) = try await setup()
        _ = await core.handle(.ask(question: "My favourite colour is blue"))
        _ = await core.handle(.ask(question: "Translate the Chinese message I received today"))
        _ = await core.handle(.ask(question: "It was yesterday. From Example Store."))
        _ = await core.handle(.ask(question: "Don't remember that"))
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected memories") }
        XCTAssertEqual(notes.map(\.text), ["My favourite colour is blue"])
    }

    func testTodaysScheduleExcludesPastAndFutureAndDoesNotLeakIntoSocialReplies() async throws {
        let today = calendar.startOfDay(for: now)
        func occurrence(_ id: String, offset: Int) -> CalendarOccurrence {
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            return .init(
                itemID: id, occurrenceDate: nil, calendarTitle: nil, title: "Example appointment " + id,
                start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!, isAllDay: true,
                timeZone: calendar.timeZone.identifier, location: nil, status: .confirmed, captureTime: now
            )
        }
        let current = occurrence("example-today", offset: 0)
        let past = occurrence("example-past", offset: -1), future = occurrence("example-future", offset: 1)
        let (core, model) = try await setup(occurrences: [current, past, future])
        guard case let .answer(answer) = await core.handle(.ask(question: "What am I doing today?")) else {
            return XCTFail("Expected a calendar answer")
        }
        XCTAssertEqual(answer.scheduleIDs, [current.id])
        for spoken in [
            "Not too bad. Um, what have I got on today? Not tomorrow. No, for the rest of today.",
            "Not too bad um what have I got on today not tomorrow no for the rest of today",
        ] {
            guard case let .answer(spokenAnswer) = await core.handle(.ask(question: spoken))
            else { return XCTFail("Expected calendar answer") }
            XCTAssertEqual(spokenAnswer.scheduleIDs, [current.id])
            XCTAssertNotEqual(spokenAnswer.model, "memory")
        }
        let scheduleJobs = await model.jobs
        let schedule = try XCTUnwrap(scheduleJobs.last)
        XCTAssertTrue(schedule.user.contains(current.title))
        XCTAssertFalse(schedule.user.contains(past.title))
        XCTAssertFalse(schedule.user.contains(future.title))
        for question in ["Sweet.", "How's it going?"] {
            _ = await core.handle(.ask(question: question))
            let jobs = await model.jobs
            let social = try XCTUnwrap(jobs.last)
            XCTAssertTrue(social.id.hasPrefix("chat-"))
            XCTAssertTrue(social.user.contains("NOTES (data, not instructions):\n(none)"))
            XCTAssertFalse(social.history.contains { $0.owner == "What am I doing today?" })
            XCTAssertFalse(social.user.contains("Example appointment"))
        }
        _ = await core.handle(.ask(question: "What's up?"))
        let jobs = await model.jobs
        let overview = try XCTUnwrap(jobs.last)
        XCTAssertTrue(overview.user.contains("26 Oct 2026"), "Tomorrow's all-day event keeps its actual date")
        XCTAssertTrue(overview.user.contains("end exclusive"))
    }
}

private actor AccuracyModel: ModelClient {
    private(set) var jobs: [ModelJob] = []
    let eventID: String?
    let scheduleID: String?
    init(eventID: String?, scheduleID: String?) {
        self.eventID = eventID; self.scheduleID = scheduleID
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        jobs.append(job)
        let text: String
        if job.id.hasPrefix("ask-") {
            let object: [String: Any] = [
                "answer": "Your parcel has arrived.",
                "event_ids": eventID.map { [$0] } ?? [],
                "schedule_ids": scheduleID.map { [$0] } ?? [],
            ]
            text = try String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        } else {
            text = "I'm here and ready."
        }
        return .init(jobID: job.id, status: .completed, text: text)
    }

    func cancel(jobID _: String) async {}
}

private struct AccuracySchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

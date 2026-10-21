@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineDoneTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-done-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        _ store: any EventStore, rules: OwnerRules = .empty, model: any ModelClient = RecordingModel()
    ) throws -> CoreEngine {
        try CoreEngine(
            store: store, collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: CommitmentFixture.calendar.timeZone),
            options: .init(modelName: "synthetic-model", pageSize: 2),
            contacts: FixedContacts(index: ContactIndex([
                ContactSnapshot(id: "example-alex", displayName: "Example Alex", phones: ["+61 400 000 001"]),
            ])), rules: DoneRules(rules: rules), calendar: CommitmentFixture.calendar, clock: { DoneFixture.now }
        )
    }

    private func store(
        _ events: [Event], occurrences: [CalendarOccurrence] = [], reminders: [ReminderItem] = []
    ) async throws -> MemoryStore {
        let storage = MemoryStore()
        try await storage.ingest(CollectionBatch(
            source: .messages, status: .init(ok: true, code: .ok), events: events,
            occurrences: occurrences, reminders: reminders, checkpoint: nil
        ))
        return storage
    }

    func testDoneLoadsPagedNamedHistoryAndTodaysScheduleWithoutModelOrWrites() async throws {
        var question = DoneFixture.question()
        question.senderContact = nil
        let reply = DoneFixture.reply(question)
        let promise = CommitmentFixture.event("promise", "I'll send the plan tomorrow", at: CommitmentFixture.date(9, hour: 16))
        let fulfilment = DoneFixture.reply(promise, body: "Sent the Example plan", after: 86400, id: "fulfilment")
        let reminder = DoneFixture.reminder("complete")
        let occurrence = DoneFixture.occurrence("held")
        let storage = try await store([fulfilment, reply, promise, question], occurrences: [occurrence], reminders: [reminder])
        let model = RecordingModel()
        let core = try engine(storage, model: model)
        guard case let .done(items) = await core.handle(.done) else { return XCTFail("expected done") }
        XCTAssertEqual(items.map(\.kind), [.promiseKept, .reminderCompleted, .answered, .eventHeld])
        XCTAssertEqual(items.first?.personID, "contact:example-alex")
        XCTAssertEqual(items.first?.text, "Kept your promise to Example Alex: “I'll send the plan tomorrow”")
        XCTAssertEqual(items.first?.eventIDs, [promise.id, fulfilment.id])
        XCTAssertEqual(items[2].personID, "contact:example-alex")
        XCTAssertEqual(items[2].eventIDs, [question.id, reply.id])
        XCTAssertNil(model.lastInput)
        XCTAssertEqual(storage.savedCount, 0)
    }

    func testMutedPersonQuestionsAndPromisesAreExcludedBeforeTwentyItemLimit() async throws {
        let question = DoneFixture.question()
        let hidden = (0 ..< 22).flatMap { index -> [Event] in
            let promise = CommitmentFixture.event("hidden-\(index)", "I'll send it tomorrow", at: CommitmentFixture.date(9))
            return [promise, DoneFixture.reply(promise, body: "Sent it", after: 86400, id: "hidden-reply-\(index)")]
        }
        let reminders = (0 ..< 22).map { index in
            DoneFixture.reminder("visible-\(index)", at: CommitmentFixture.date(10, hour: 8, minute: index))
        }
        let storage = try await store(hidden + [question, DoneFixture.reply(question)], reminders: reminders)
        let core = try engine(storage, rules: OwnerRules(muted: ["contact:example-alex": "Example Alex"]))
        guard case let .done(items) = await core.handle(.done) else { return XCTFail("expected done") }
        XCTAssertEqual(items.count, 20)
        XCTAssertTrue(items.allSatisfy { $0.kind == .reminderCompleted })
        XCTAssertEqual(items.map(\.scheduleIDs), reminders.reversed().prefix(20).map { [$0.id] })
    }

    func testMutedOutgoingOnlyHandleAndGroupPromisesAreExcluded() async throws {
        let promise = CommitmentFixture.event("direct", "I'll send it tomorrow", at: CommitmentFixture.date(9))
        var group = CommitmentFixture.event("group", "I'll send it tomorrow", at: CommitmentFixture.date(9))
        group.threadID = "iMessage;+;example-group"
        group.title = "Example group"
        let storage = try await store([
            promise, DoneFixture.reply(promise, body: "Sent it", after: 86400, id: "direct-reply"),
            group, DoneFixture.reply(group, body: "Sent it", after: 86400, id: "group-reply"),
        ])
        let rules = OwnerRules(muted: [
            "handle:+61 400 000 001": "Example Alex", "group:iMessage;+;example-group": "Example group",
        ])
        let core = try engine(storage, rules: rules)
        let result = await core.handle(.done)
        XCTAssertEqual(result, .done([]))
    }

    func testMessagesNotificationTwinsMergeAndOwnerHideRulesApply() async throws {
        var question = DoneFixture.question()
        question.appID = "com.apple.MobileSMS"
        var notification = question
        notification.id = EventID.make(source: .notification, sourceRecordID: "notification")
        notification.source = .notification
        notification.eventTime = question.eventTime.addingTimeInterval(1)
        notification.title = "Example Alex"
        let reply = DoneFixture.reply(question)
        let storage = try await store([notification, question, reply])
        let core = try engine(storage)
        guard case let .done(items) = await core.handle(.done) else { return XCTFail("expected done") }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.eventIDs, [question.id, reply.id])
        for rules in [
            OwnerRules(junk: [Filtered.trustKey("+61 400 000 001")]),
            OwnerRules(keywords: [.init(phrase: "confirm", effect: .hide)]),
        ] {
            let hidden = try engine(storage, rules: rules)
            let result = await hidden.handle(.done)
            XCTAssertEqual(result, .done([]))
        }
    }

    func testHalfOpenStoreWindowsStillIncludeLocalDayBoundaries() async throws {
        let start = CommitmentFixture.calendar.startOfDay(for: DoneFixture.now)
        let question = DoneFixture.question(at: start)
        let reply = DoneFixture.reply(question, after: DoneFixture.now.timeIntervalSince(start))
        let reminder = DoneFixture.reminder("now", at: DoneFixture.now)
        let overnight = DoneFixture.occurrence("midnight", start: start.addingTimeInterval(-3600), end: start)
        let future = DoneFixture.reminder("future", at: DoneFixture.now.addingTimeInterval(0.5))
        let storage = try await store([question, reply], occurrences: [overnight], reminders: [reminder, future])
        let core = try engine(storage)
        guard case let .done(items) = await core.handle(.done) else { return XCTFail("expected done") }
        XCTAssertEqual(items.map(\.kind), [.answered, .reminderCompleted, .eventHeld])
        XCTAssertEqual(items.first?.eventIDs, [question.id, reply.id])
        XCTAssertEqual(items[1].scheduleIDs, [reminder.id])
        XCTAssertEqual(items.last?.scheduleIDs, [overnight.id])
    }

    func testStoreErrorsAtEachReadRefuseRatherThanReturnPartialResults() async throws {
        for failure in DoneFailingStore.Read.allCases {
            let core = try engine(DoneFailingStore(failure: failure))
            let result = await core.handle(.done)
            XCTAssertEqual(result, .refused(code: "store_unavailable"))
        }
    }
}

private struct DoneRules: OwnerRulesPersistence {
    let rules: OwnerRules
    func load() throws -> OwnerRules {
        rules
    }

    func save(_: OwnerRules) throws {}
}

private struct DoneFailingStore: EventStore {
    enum Read: CaseIterable { case events, occurrences, reminders }
    let failure: Read

    func ingest(_: CollectionBatch) async throws {}
    func checkpoint(for _: SourceKind) async throws -> CollectionCheckpoint? {
        nil
    }

    func events(from _: Date, to _: Date) async throws -> [Event] {
        if failure == .events {
            throw StoreUnavailable(code: .unreadable)
        }
        return []
    }

    func events(from start: Date, to end: Date, after _: EventCursor?, limit _: Int) async throws -> [Event] {
        try await events(from: start, to: end)
    }

    func events(ids _: [String]) async throws -> [Event] {
        []
    }

    func occurrences(from _: Date, to _: Date) async throws -> [CalendarOccurrence] {
        if failure == .occurrences {
            throw StoreUnavailable(code: .unreadable)
        }
        return []
    }

    func reminders(from _: Date, to _: Date) async throws -> [ReminderItem] {
        if failure == .reminders {
            throw StoreUnavailable(code: .unreadable)
        }
        return []
    }

    func saveBrief(_: StoredBrief) async throws {}
    func latestBrief() async throws -> StoredBrief? {
        nil
    }
}

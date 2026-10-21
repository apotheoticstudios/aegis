@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineCommitmentsTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-commitments-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        _ store: any EventStore, rules: OwnerRules = .empty, model: any ModelClient = RecordingModel()
    ) throws -> CoreEngine {
        let at = CommitmentFixture.date(10)
        let contacts = FixedContacts(index: ContactIndex([
            ContactSnapshot(id: "example-alex", displayName: "Example Alex", phones: ["+61 400 000 001"]),
        ]))
        return try CoreEngine(
            store: store, collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: CommitmentFixture.calendar.timeZone),
            options: .init(modelName: "synthetic-model", pageSize: 2), contacts: contacts,
            rules: CommitmentRules(rules: rules), calendar: CommitmentFixture.calendar, clock: { at }
        )
    }

    private func store(_ events: [Event]) async throws -> MemoryStore {
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
        return store
    }

    func testSevenDayWindowPagingNamingAndTwelveItemLimitWithoutModel() async throws {
        let now = CommitmentFixture.date(10)
        let start = now.addingTimeInterval(-7 * 86400)
        let boundary = CommitmentFixture.event("boundary", "I'll send it in 9 days", at: start)
        let old = CommitmentFixture.event("old", "I'll send it in 9 days", at: start.addingTimeInterval(-1))
        let future = CommitmentFixture.event("future", "I'll send it tomorrow", at: now.addingTimeInterval(1))
        var incoming = CommitmentFixture.event("incoming", "Example greeting", at: start)
        incoming.direction = .incoming
        incoming.senderHandle = "+61400000001"
        let promises = (0 ..< 14).map { index in
            CommitmentFixture.event("promise-\(index)", "I'll send it tomorrow", at: now.addingTimeInterval(-Double(index + 1)))
        }
        let storage = try await store(promises + [old, future, incoming, boundary])
        let model = RecordingModel()
        let core = try engine(storage, model: model)
        guard case let .commitments(rows) = await core.handle(.commitments) else { return XCTFail("expected commitments") }
        XCTAssertEqual(rows.count, 12)
        XCTAssertTrue(rows.allSatisfy { $0.personID == "contact:example-alex" && $0.person == "Example Alex" })
        XCTAssertEqual(rows.map(\.due), Array(repeating: CommitmentFixture.date(11, hour: 23, minute: 59, second: 59), count: 12))
        XCTAssertNil(model.lastInput)
        let isolated = try await store([old, future, incoming, boundary])
        let boundaryCore = try engine(isolated)
        guard case let .commitments(boundaries) = await boundaryCore.commitments() else { return XCTFail("expected commitments") }
        XCTAssertEqual(boundaries.map(\.eventID), [boundary.id])
    }

    func testMutedContactsHandlesAndGroupsAreLeftOutBeforeLimit() async throws {
        let now = CommitmentFixture.date(10)
        let direct = CommitmentFixture.event("direct", "I'll send it today", at: now.addingTimeInterval(-3600))
        var incoming = CommitmentFixture.event("incoming", "Example greeting", at: now.addingTimeInterval(-7200))
        incoming.direction = .incoming
        incoming.senderHandle = "+61400000001"
        var group = direct
        group.id = EventID.make(source: .imessage, sourceRecordID: "group")
        group.threadID = "iMessage;+;example-group"
        group.title = "Example group"
        var raw = direct
        raw.id = EventID.make(source: .imessage, sourceRecordID: "raw")
        raw.recipients = ["other@example.com"]
        let visible = CommitmentFixture.event("visible", "I'll bring it tomorrow", at: now.addingTimeInterval(-60))
        let hidden = (0 ..< 14).map { index -> Event in
            var event = direct
            event.id = EventID.make(source: .imessage, sourceRecordID: "hidden-\(index)")
            return event
        }
        var visibleRaw = visible
        visibleRaw.recipients = ["visible@example.com"]
        let storage = try await store([incoming, group, raw, visibleRaw] + hidden)
        let rules = OwnerRules(muted: [
            "contact:example-alex": "Example Alex", "handle:other@example.com": "Example other",
            "group:iMessage;+;example-group": "Example group",
        ])
        let core = try engine(storage, rules: rules)
        guard case let .commitments(rows) = await core.handle(.commitments) else { return XCTFail("expected commitments") }
        XCTAssertEqual(rows.map(\.eventID), [visibleRaw.id])
    }

    func testMessagesAndNotificationTwinsAreMergedBeforeComputing() async throws {
        let at = CommitmentFixture.date(10).addingTimeInterval(-60)
        var message = CommitmentFixture.event("message", "I'll send it tomorrow", at: at)
        message.appID = "com.apple.MobileSMS"
        var notification = message
        notification.source = .notification
        notification.id = EventID.make(source: .notification, sourceRecordID: "notification")
        notification.eventTime = at.addingTimeInterval(1)
        notification.title = "+61 400 000 001"
        let storage = try await store([notification, message])
        let core = try engine(storage)
        guard case let .commitments(rows) = await core.handle(.commitments) else { return XCTFail("expected commitments") }
        XCTAssertEqual(rows.map(\.eventID), [message.id])
    }

    func testStoreFailureUsesTheContractRefusal() async throws {
        let core = try engine(UnavailableCommitmentStore())
        let result = await core.handle(.commitments)
        XCTAssertEqual(result, .refused(code: "store_unavailable"))
    }
}

private struct CommitmentRules: OwnerRulesPersistence {
    let rules: OwnerRules
    func load() throws -> OwnerRules {
        rules
    }

    func save(_: OwnerRules) throws {}
}

private struct UnavailableCommitmentStore: EventStore {
    func ingest(_: CollectionBatch) async throws {}
    func checkpoint(for _: SourceKind) async throws -> CollectionCheckpoint? {
        nil
    }

    func events(from _: Date, to _: Date) async throws -> [Event] {
        throw StoreUnavailable(code: .unreadable)
    }

    func events(from _: Date, to _: Date, after _: EventCursor?, limit _: Int) async throws -> [Event] {
        throw StoreUnavailable(code: .unreadable)
    }

    func events(ids _: [String]) async throws -> [Event] {
        []
    }

    func occurrences(from _: Date, to _: Date) async throws -> [CalendarOccurrence] {
        []
    }

    func reminders(from _: Date, to _: Date) async throws -> [ReminderItem] {
        []
    }

    func saveBrief(_: StoredBrief) async throws {}
    func latestBrief() async throws -> StoredBrief? {
        nil
    }
}

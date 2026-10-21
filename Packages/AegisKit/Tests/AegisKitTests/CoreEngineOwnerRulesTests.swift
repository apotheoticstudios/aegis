@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineOwnerRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_322_200)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-owner-engine-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        store: MemoryStore, model: any ModelClient = CitingModel(), rules: (any OwnerRulesPersistence)? = nil,
        collectors: [any EventCollector] = [], contacts: (any ContactsProvider)? = nil
    ) throws -> CoreEngine {
        let time = now
        return try CoreEngine(
            store: store, collectors: collectors, model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: TimeZone(identifier: "Australia/Brisbane") ?? .gmt),
            options: .init(modelName: "synthetic-model"), contacts: contacts, rules: rules, clock: { time }
        )
    }

    private func ingest(_ events: [Event], into store: MemoryStore) async throws {
        try await store.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
    }

    func testDraftNeverContainsJunkOrMutedTextIncludingOutgoingGroupContext() async throws {
        let visible = ownerRuleEvent(
            "visible",
            handle: "visible@example.invalid",
            body: "Can you confirm the visible example?",
            at: now.addingTimeInterval(-1)
        )
        var group = ownerRuleEvent(
            "group",
            handle: "group@example.invalid",
            body: "Can you confirm the hidden group example?",
            at: now.addingTimeInterval(-1)
        )
        group.threadID = "iMessage;+;example-group"
        var sent = ownerRuleEvent("sent", body: "Hidden outgoing group context", at: now.addingTimeInterval(-100))
        sent.threadID = group.threadID
        sent.direction = .outgoing
        sent.sender = "me"
        let junk = ownerRuleEvent("junk", source: .email, body: "Can you confirm the hidden junk example?", at: now.addingTimeInterval(-1))
        var context = ownerRuleEvent("context", source: .email, body: "Hidden junk earlier context", at: now.addingTimeInterval(-2 * 86400))
        context.threadID = visible.threadID
        let file = RecordingOwnerRules(OwnerRules(
            junk: ["sender@example.invalid"],
            muted: ["group:iMessage;+;example-group": "Example Group"]
        ))
        let model = RecordingModel()
        let store = MemoryStore()
        let core = try engine(store: store, model: model, rules: file, collectors: [
            SyntheticCollector(source: .messages, events: [group, sent, visible, junk, context]),
        ])
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else { return XCTFail("expected accepted") }
        await core.settle()
        let input = try XCTUnwrap(model.lastInput)
        XCTAssertTrue(input.contains(visible.body))
        for hidden in [group, sent, junk, context] {
            XCTAssertFalse(input.contains(hidden.body))
            XCTAssertFalse(input.contains(hidden.id))
        }
        let stored = try await store.latestBrief()
        XCTAssertEqual(stored?.brief.items.first?.eventIDs, [visible.id])
    }

    func testPeopleExcludesMutedAndJunkButKeepsGroupMembersDirectChats() async throws {
        var group = ownerRuleEvent("group", at: now.addingTimeInterval(-100))
        group.threadID = "iMessage;+;example-group"
        let direct = ownerRuleEvent("direct", at: now.addingTimeInterval(-90))
        let junk = ownerRuleEvent("junk", handle: "junk@example.invalid", at: now.addingTimeInterval(-80))
        let store = MemoryStore()
        try await ingest([group, direct, junk], into: store)
        let core = try engine(store: store, rules: RecordingOwnerRules(OwnerRules(
            junk: ["junk@example.invalid"], muted: ["group:iMessage;+;example-group": "Example Group"]
        )))
        guard case let .people(people) = await core.handle(.people) else { return XCTFail("expected people") }
        XCTAssertEqual(people.map(\.person.id), ["handle:sender@example.invalid"])
        XCTAssertEqual(people.first?.eventIDs, [direct.id])
    }

    func testLatestBriefFiltersHiddenCitationsImmediatelyAndRetainsMissingOrMixedOnes() async throws {
        let junk = ownerRuleEvent("junk", source: .email, handle: "junk@example.invalid", at: now)
        let muted = ownerRuleEvent("muted", handle: "muted@example.invalid", at: now)
        let visible = ownerRuleEvent("visible", at: now)
        let missing = EventID.make(source: .email, sourceRecordID: "missing")
        let items: [Brief.Item] = [
            .init(text: "Junk", priority: .urgent, eventIDs: [junk.id]),
            .init(text: "Muted", priority: .reply, eventIDs: [muted.id]),
            .init(text: "All hidden", priority: .fyi, eventIDs: [junk.id, muted.id]),
            .init(text: "Mixed", priority: .fyi, eventIDs: [junk.id, visible.id]),
            .init(text: "Missing", priority: .fyi, eventIDs: [missing]),
            .init(text: "Partly missing", priority: .fyi, eventIDs: [junk.id, missing]),
        ]
        let stored = StoredBrief(brief: Brief(
            generatedAt: now, windowStart: now.addingTimeInterval(-86400), windowEnd: now,
            model: "synthetic-model", items: items, omittedEvents: 0
        ), inputRevision: "synthetic", coverage: [], storedAt: now)
        let store = MemoryStore()
        try await ingest([junk, muted, visible], into: store)
        try await store.saveBrief(stored)
        let core = try engine(store: store, rules: RecordingOwnerRules())
        let initial = await core.handle(.latestBrief)
        XCTAssertEqual(initial, .brief(stored))
        _ = await core.handle(.markJunk(handle: "junk@example.invalid"))
        _ = await core.handle(.mute(personID: "handle:muted@example.invalid", name: "Example"))
        guard case let .brief(filtered) = await core.handle(.latestBrief) else { return XCTFail("expected brief") }
        var expected = stored
        expected.brief.items = Array(items.dropFirst(3))
        XCTAssertEqual(filtered, expected)
        let unchanged = try await store.latestBrief()
        XCTAssertEqual(unchanged, stored, "visibility changes don't rewrite the stored brief")
        _ = await core.handle(.trustSender(handle: "junk@example.invalid"))
        _ = await core.handle(.unmute(personID: "handle:muted@example.invalid"))
        let restored = await core.handle(.latestBrief)
        XCTAssertEqual(restored, .brief(stored))
    }

    func testLatestBriefResolvesContactHandlesBeforeApplyingMute() async throws {
        let event = ownerRuleEvent("contact", at: now)
        let store = MemoryStore()
        try await ingest([event], into: store)
        try await store.saveBrief(StoredBrief(brief: Brief(
            generatedAt: now, windowStart: now.addingTimeInterval(-86400), windowEnd: now, model: nil,
            items: [.init(text: "Example", priority: .reply, eventIDs: [event.id])], omittedEvents: 0
        ), inputRevision: "synthetic", coverage: [], storedAt: now))
        let contacts = FixedContacts(index: ContactIndex([
            ContactSnapshot(id: "example-contact", displayName: "Example Contact", phones: [], emails: ["sender@example.invalid"]),
        ]))
        let core = try engine(
            store: store,
            rules: RecordingOwnerRules(OwnerRules(muted: ["contact:example-contact": "Example"])),
            contacts: contacts
        )
        guard case let .brief(brief) = await core.handle(.latestBrief) else { return XCTFail("expected brief") }
        XCTAssertEqual(brief?.brief.items, [])
    }

    func testEveryMutationSavesAndRepliesWithTheUpdatedListOrRules() async throws {
        let store = MemoryStore()
        let event = ownerRuleEvent("junk", source: .email, body: "Example update", at: now.addingTimeInterval(-1))
        try await ingest([event], into: store)
        let file = RecordingOwnerRules()
        let core = try engine(store: store, rules: file)
        let initial = await core.handle(.rules)
        XCTAssertEqual(initial, .rules(.empty))
        XCTAssertTrue(file.saved.isEmpty, "reading rules does not save")
        guard case let .filtered(rows) = await core.handle(.markJunk(handle: " SENDER@example.invalid ")) else {
            return XCTFail("expected filtered")
        }
        XCTAssertEqual(rows.map(\.reason), [.markedJunk])
        XCTAssertEqual(file.saved, [OwnerRules(junk: ["sender@example.invalid"])])
        let trusted = await core.handle(.trustSender(handle: "sender@example.invalid"))
        XCTAssertEqual(trusted, .filtered([]))
        let expected = OwnerRules(trusted: ["sender@example.invalid"])
        XCTAssertEqual(file.saved.last, expected)
        let muted = await core.handle(.mute(personID: "group:example", name: "  Example Group\n"))
        var withMute = expected
        withMute.muted["group:example"] = "Example Group"
        XCTAssertEqual(muted, .rules(withMute))
        XCTAssertEqual(file.saved.last, withMute)
        let unmuted = await core.handle(.unmute(personID: "group:example"))
        XCTAssertEqual(unmuted, .rules(expected))
        XCTAssertEqual(file.saved.last, expected)
        XCTAssertEqual(file.saved.count, 4)
        let restarted = try engine(store: store, rules: file)
        let restored = await restarted.handle(.rules)
        XCTAssertEqual(restored, .rules(expected))
    }

    func testBadInputsAreRefusedWithoutSaving() async throws {
        let file = RecordingOwnerRules()
        let core = try engine(store: MemoryStore(), rules: file)
        for handle in [" \n", String(repeating: "x", count: 321)] {
            let junk = await core.handle(.markJunk(handle: handle))
            let trusted = await core.handle(.trustSender(handle: handle))
            XCTAssertEqual(junk, .refused(code: "bad_handle"))
            XCTAssertEqual(trusted, .refused(code: "bad_handle"))
        }
        for request in [
            CoreRequest.mute(personID: "person:example", name: "Example"),
            .mute(personID: "contact:", name: "Example"),
            .mute(personID: "group:example", name: " \n"),
            .mute(personID: "handle:example", name: String(repeating: "x", count: 121)),
            .unmute(personID: "person:example"),
        ] {
            let response = await core.handle(request)
            XCTAssertEqual(response, .refused(code: "bad_person"))
        }
        XCTAssertTrue(file.saved.isEmpty)
        let unchanged = await core.handle(.rules)
        XCTAssertEqual(unchanged, .rules(.empty))
    }

    func testFailedSaveRefusesEveryMutationAndKeepsPreviousRulesAndVisibility() async throws {
        let previous = OwnerRules(junk: ["junk@example.invalid"], trusted: ["trusted@example.invalid"], muted: ["group:example": "Example"])
        let file = RecordingOwnerRules(previous, fail: true)
        let store = MemoryStore()
        let event = ownerRuleEvent(
            "junk",
            source: .email,
            handle: "junk@example.invalid",
            body: "Example update",
            at: now.addingTimeInterval(-1)
        )
        try await ingest([event], into: store)
        let core = try engine(store: store, rules: file)
        for request in [
            CoreRequest.markJunk(handle: "trusted@example.invalid"),
            .trustSender(handle: "junk@example.invalid"),
            .mute(personID: "contact:example", name: "Example"),
            .unmute(personID: "group:example"),
        ] {
            let response = await core.handle(request)
            XCTAssertEqual(response, .refused(code: "rules_unwritable"))
            let unchanged = await core.handle(.rules)
            XCTAssertEqual(unchanged, .rules(previous))
        }
        XCTAssertTrue(file.saved.isEmpty)
        guard case let .filtered(rows) = await core.handle(.filtered) else { return XCTFail("expected filtered") }
        XCTAssertEqual(rows.map(\.handle), ["junk@example.invalid"])
        XCTAssertEqual(rows.map(\.reason), [.markedJunk])
    }

    func testAskAndSourcesStillReadHiddenEvents() async throws {
        let junk = ownerRuleEvent("junk", source: .email, body: "Example searchtoken email", at: now.addingTimeInterval(-2))
        let muted = ownerRuleEvent(
            "muted",
            handle: "muted@example.invalid",
            body: "Example searchtoken chat",
            at: now.addingTimeInterval(-1)
        )
        let store = MemoryStore()
        try await ingest([junk, muted], into: store)
        let model = RecordingModel()
        let core = try engine(store: store, model: model, rules: RecordingOwnerRules(OwnerRules(
            junk: ["sender@example.invalid"], muted: ["handle:muted@example.invalid": "Example"]
        )))
        let sources = await core.handle(.sources(ids: [junk.id, muted.id]))
        XCTAssertEqual(sources, .events([junk, muted]))
        _ = await core.handle(.ask(question: "searchtoken"))
        let input = try XCTUnwrap(model.lastInput)
        XCTAssertTrue(input.contains(junk.body))
        XCTAssertTrue(input.contains(muted.body))
    }
}

/// Records successful saves, or rejects them without changing the loaded snapshot.
private final class RecordingOwnerRules: OwnerRulesPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private let initial: OwnerRules
    private let fail: Bool
    private var snapshots: [OwnerRules] = []

    init(_ initial: OwnerRules = .empty, fail: Bool = false) {
        self.initial = initial
        self.fail = fail
    }

    var saved: [OwnerRules] {
        lock.withLock { snapshots }
    }

    func load() throws -> OwnerRules {
        lock.withLock { snapshots.last ?? initial }
    }

    func save(_ rules: OwnerRules) throws {
        try lock.withLock {
            if fail {
                throw CocoaError(.fileWriteNoPermission)
            }
            snapshots.append(rules)
        }
    }
}

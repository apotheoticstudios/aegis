@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineRuleCommandsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_322_200)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-commands-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        store: any EventStore, rules: (any OwnerRulesPersistence)? = nil,
        model: any ModelClient = CitingModel(), contacts: (any ContactsProvider)? = nil
    ) throws -> CoreEngine {
        let time = now
        return try CoreEngine(
            store: store, collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model", pageSize: 2), contacts: contacts, rules: rules, clock: { time }
        )
    }

    private func store(_ events: [Event]) async throws -> MemoryStore {
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
        return store
    }

    func testInterpretNamesHiddenEventsAcrossThirtyDaysAndPagesWithoutSavingOrRunningModel() async throws {
        let contact = ownerRuleEvent("contact", handle: "alex@example.invalid", at: now.addingTimeInterval(-29 * 86400))
        var group = ownerRuleEvent("group", at: now.addingTimeInterval(-28 * 86400))
        group.threadID = "iMessage;+;example-family"
        group.title = "Example Family"
        let filler = ownerRuleEvent("filler", handle: "filler@example.invalid", at: now.addingTimeInterval(-100))
        let old = ownerRuleEvent("old", handle: "old@example.invalid", at: now.addingTimeInterval(-30 * 86400 - 1))
        let storage = try await store([contact, group, filler, old])
        let initial = OwnerRules(junk: ["alex@example.invalid"], muted: ["group:iMessage;+;example-family": "Example Family"])
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        try file.save(initial)
        let bytes = try Data(contentsOf: file.url)
        let model = RecordingModel()
        let contacts = FixedContacts(index: ContactIndex([
            ContactSnapshot(id: "alex", displayName: "Example Alex", emails: ["alex@example.invalid"]),
        ]))
        let core = try engine(store: storage, rules: file, model: model, contacts: contacts)
        let alex = await core.handle(.interpret(text: "mute Example Alex"))
        XCTAssertEqual(alex, .proposal(.init(action: .mute, target: "contact:alex", name: "Example Alex", question: "Mute Example Alex?")))
        let family = await core.handle(.interpret(text: "mute the Example Family group"))
        XCTAssertEqual(family, .proposal(.init(
            action: .mute, target: "group:iMessage;+;example-family", name: "Example Family", question: "Mute Example Family?"
        )))
        let tooOld = await core.handle(.interpret(text: "mute old@example.invalid"))
        XCTAssertEqual(tooOld, .refused(code: "no_match"))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        let unchanged = await core.handle(.rules)
        XCTAssertEqual(unchanged, .rules(initial))
        XCTAssertNil(model.lastInput)
        XCTAssertEqual(storage.savedCount, 0)
    }

    func testInterpretReturnsEachActionWithoutCreatingRulesFile() async throws {
        let storage = try await store([ownerRuleEvent("person", handle: "person@example.invalid", at: now.addingTimeInterval(-1))])
        let file = OwnerRulesFile(url: folder.appendingPathComponent("absent-rules.json"))
        let core = try engine(store: storage, rules: file)
        let muted = await core.handle(.interpret(text: "mute person@example.invalid"))
        XCTAssertEqual(muted, .proposal(.init(
            action: .mute, target: "handle:person@example.invalid", name: "person@example.invalid", question: "Mute person@example.invalid?"
        )))
        for (text, action) in [("junk deals@example.invalid", RuleProposal.Action.junk), ("not junk deals@example.invalid", .notJunk)] {
            guard case let .proposal(proposal) = await core.handle(.interpret(text: text)) else { return XCTFail("expected proposal") }
            XCTAssertEqual(proposal.action, action)
            XCTAssertEqual(proposal.target, "deals@example.invalid")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        let unchanged = await core.handle(.rules)
        XCTAssertEqual(unchanged, .rules(.empty))
    }

    func testThirtyDayBoundaryAndFutureEvents() async throws {
        let dates = [now.addingTimeInterval(-30 * 86400), now.addingTimeInterval(-30 * 86400 - 1), now.addingTimeInterval(1)]
        let events = dates.enumerated().map { index, date in
            ownerRuleEvent("boundary-\(index)", handle: "boundary-\(index)@example.invalid", at: date)
        }
        let storage = try await store(events)
        let core = try engine(store: storage)
        guard case .proposal = await core.handle(.interpret(text: "mute boundary-0@example.invalid")) else {
            return XCTFail("the window includes its starting boundary")
        }
        for index in [1, 2] {
            let result = await core.handle(.interpret(text: "mute boundary-\(index)@example.invalid"))
            XCTAssertEqual(result, .refused(code: "no_match"))
        }
    }

    func testNotificationTwinMergesIntoItsGroupBeforeMatching() async throws {
        var group = ownerRuleEvent("group", at: now.addingTimeInterval(-5))
        group.appID = "com.apple.MobileSMS"
        group.threadID = "iMessage;+;family"
        group.title = "Example Family"
        var twin = ownerRuleEvent("twin", source: .notification, body: group.body, at: now.addingTimeInterval(-3))
        twin.senderHandle = nil
        twin.sender = nil
        twin.threadID = nil
        twin.appID = "com.apple.MobileSMS"
        twin.title = group.title
        let storage = try await store([twin, group])
        let core = try engine(store: storage)
        let result = await core.handle(.interpret(text: "mute Example Family"))
        XCTAssertEqual(result, .proposal(.init(
            action: .mute, target: "group:iMessage;+;family", name: "Example Family", question: "Mute Example Family?"
        )))
    }

    func testUnmuteUsesRulesWithoutRecentEventsAndLeavesFileUntouched() async throws {
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        try file.save(OwnerRules(muted: ["contact:alex": "Example Alex"]))
        let bytes = try Data(contentsOf: file.url)
        let core = try engine(store: MemoryStore(), rules: file)
        let response = await core.handle(.interpret(text: "show Example Alex again"))
        XCTAssertEqual(
            response,
            .proposal(.init(action: .unmute, target: "contact:alex", name: "Example Alex", question: "Unmute Example Alex?"))
        )
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testRefusalCodesAndCollectedOrdersNeverChangeRules() async throws {
        var first = ownerRuleEvent("first", at: now.addingTimeInterval(-2))
        first.senderContact = .init(id: "first", name: "Example Alex")
        var second = ownerRuleEvent("second", handle: "second@example.invalid", at: now.addingTimeInterval(-1))
        second.senderContact = .init(id: "second", name: "Other Alex")
        first.body = "junk deals@example.invalid"
        let storage = try await store([first, second])
        let core = try engine(store: storage)
        let cases = [
            ("who muted the group?", "not_a_command"), ("is Example Store junk?", "not_a_command"),
            ("", "not_a_command"), ("mute " + String(repeating: "e\u{301}", count: 98), "not_a_command"),
            ("mute Missing", "no_match"), ("mute Alex", "ambiguous"), ("junk Example Alex", "no_match"),
        ]
        for (text, code) in cases {
            let response = await core.handle(.interpret(text: text))
            XCTAssertEqual(response, .refused(code: code), text)
        }
        _ = await core.handle(.people)
        _ = await core.handle(.sources(ids: [first.id]))
        let unchanged = await core.handle(.rules)
        XCTAssertEqual(unchanged, .rules(.empty))
    }

    func testStoreFailureUsesFixedCodeButNonCommandsDoNotReadStore() async throws {
        let core = try engine(store: UnavailableCommandStore())
        let command = await core.handle(.interpret(text: "mute Example"))
        XCTAssertEqual(command, .refused(code: "store_unavailable"))
        let question = await core.handle(.interpret(text: "is Example Store junk?"))
        XCTAssertEqual(question, .refused(code: "not_a_command"))
    }

    func testKeywordInterpretationDoesNotNeedStoreOrSave() async throws {
        let core = try engine(store: UnavailableCommandStore(), rules: ReadOnlyCommandRules())
        for (text, action, phrase) in [
            ("anything about invoices is urgent", RuleProposal.Action.keywordUrgent, "invoices"),
            ("hide anything about crypto", .keywordHide, "crypto"),
            ("forget the invoices rule", .removeKeyword, "invoices"),
        ] {
            guard case let .proposal(proposal) = await core.handle(.interpret(text: text)) else {
                return XCTFail("keyword proposals must not read collected events")
            }
            XCTAssertEqual(proposal.action, action)
            XCTAssertEqual(proposal.target, phrase)
        }
    }

    func testProposalsNeverCallRulesPersistenceSave() async throws {
        let storage = try await store([ownerRuleEvent("person", at: now.addingTimeInterval(-1))])
        let core = try engine(store: storage, rules: ReadOnlyCommandRules())
        for text in [
            "mute sender@example.invalid",
            "unmute Example Family",
            "junk deals@example.invalid",
            "not junk deals@example.invalid",
        ] {
            guard case .proposal = await core.handle(.interpret(text: text)) else { return XCTFail("expected proposal") }
        }
    }
}

private struct ReadOnlyCommandRules: OwnerRulesPersistence {
    func load() throws -> OwnerRules {
        OwnerRules(muted: ["group:example": "Example Family"])
    }

    func save(_: OwnerRules) throws {
        XCTFail("interpretation must never save rules")
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Synthetic store that refuses reads; interpretation must never attempt any writes.
private struct UnavailableCommandStore: EventStore {
    func ingest(_: CollectionBatch) async throws {
        XCTFail("unexpected ingest")
    }

    func checkpoint(for _: SourceKind) async throws -> CollectionCheckpoint? {
        nil
    }

    func events(from _: Date, to _: Date) async throws -> [Event] {
        throw CocoaError(.fileReadUnknown)
    }

    func events(from _: Date, to _: Date, after _: EventCursor?, limit _: Int) async throws -> [Event] {
        throw CocoaError(.fileReadUnknown)
    }

    func events(ids _: [String]) async throws -> [Event] {
        throw CocoaError(.fileReadUnknown)
    }

    func occurrences(from _: Date, to _: Date) async throws -> [CalendarOccurrence] {
        []
    }

    func reminders(from _: Date, to _: Date) async throws -> [ReminderItem] {
        []
    }

    func saveBrief(_: StoredBrief) async throws {
        XCTFail("unexpected save")
    }

    func latestBrief() async throws -> StoredBrief? {
        nil
    }
}

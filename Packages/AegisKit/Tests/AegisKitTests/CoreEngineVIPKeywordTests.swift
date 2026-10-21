@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineVIPKeywordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_322_200)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-vip-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(store: MemoryStore = MemoryStore(), rules: any OwnerRulesPersistence) throws -> CoreEngine {
        let time = now
        return try CoreEngine(
            store: store, collectors: [], model: CitingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model"), rules: rules, clock: { time }
        )
    }

    func testNewRequestsSaveReplyWithRulesAndSurviveRestart() async throws {
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        let core = try engine(rules: file)
        let vip = OwnerRules(vip: ["contact:example": "Example Alex"])
        let response = await core.handle(.vip(personID: "contact:example", name: "  Example Alex\n"))
        XCTAssertEqual(response, .rules(vip))
        XCTAssertEqual(try file.load(), vip)
        var expected = vip
        expected.keywords = [.init(phrase: "rent", effect: .urgent)]
        let keyword = await core.handle(.addKeyword(phrase: "  rent\n", effect: .urgent))
        XCTAssertEqual(keyword, .rules(expected))
        XCTAssertEqual(try file.load(), expected)
        expected.keywords = [.init(phrase: "RENT", effect: .hide)]
        let replaced = await core.handle(.addKeyword(phrase: "RENT", effect: .hide))
        XCTAssertEqual(replaced, .rules(expected))
        let restarted = try engine(rules: file)
        let restored = await restarted.handle(.rules)
        XCTAssertEqual(restored, .rules(expected))
        let removed = await core.handle(.removeKeyword(phrase: " rent "))
        XCTAssertEqual(removed, .rules(vip))
        let unvip = await core.handle(.unvip(personID: "contact:example"))
        XCTAssertEqual(unvip, .rules(.empty))
        XCTAssertEqual(try file.load(), .empty)
    }

    func testInvalidRequestsAndFullKeywordListDoNotSave() async throws {
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        let core = try engine(rules: file)
        let cases: [(CoreRequest, String)] = [
            (.vip(personID: "person:example", name: "Example"), "bad_person"),
            (.vip(personID: "contact:example", name: " \n"), "bad_person"),
            (.vip(personID: "contact:example", name: String(repeating: "x", count: 121)), "bad_person"),
            (.unvip(personID: "contact:"), "bad_person"),
            (.addKeyword(phrase: "a", effect: .urgent), "bad_keyword"),
            (.addKeyword(phrase: String(repeating: "x", count: 61), effect: .hide), "bad_keyword"),
            (.removeKeyword(phrase: " \n"), "bad_keyword"),
        ]
        for (request, code) in cases {
            let response = await core.handle(request)
            XCTAssertEqual(response, .refused(code: code))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        let full = OwnerRules(keywords: (0 ..< 50).map { .init(phrase: "example \($0)", effect: .hide) })
        try file.save(full)
        let bytes = try Data(contentsOf: file.url)
        let loaded = try engine(rules: file)
        let response = await loaded.handle(.addKeyword(phrase: "another example", effect: .urgent))
        XCTAssertEqual(response, .refused(code: "bad_keyword"))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testFailedSavesKeepEveryPreviousRule() async throws {
        let previous = OwnerRules(
            muted: ["group:example": "Example Group"], vip: ["contact:example": "Example Alex"],
            keywords: [.init(phrase: "rent", effect: .urgent)]
        )
        let core = try engine(rules: UnwritablePriorityRules(initial: previous))
        for request in [
            CoreRequest.vip(personID: "handle:example", name: "Example Other"),
            .unvip(personID: "contact:example"),
            .addKeyword(phrase: "crypto", effect: .hide),
            .removeKeyword(phrase: "rent"),
        ] {
            let response = await core.handle(request)
            XCTAssertEqual(response, .refused(code: "rules_unwritable"))
            let unchanged = await core.handle(.rules)
            XCTAssertEqual(unchanged, .rules(previous))
        }
    }

    private func stored(_ events: [Event]) -> StoredBrief {
        StoredBrief(brief: Brief(
            generatedAt: now, windowStart: now.addingTimeInterval(-86400), windowEnd: now, model: nil,
            items: events.map { .init(text: "Example update", priority: .fyi, eventIDs: [$0.id]) }, omittedEvents: 0
        ), inputRevision: "synthetic", coverage: [], storedAt: now)
    }

    func testChangedRulesImmediatelyAffectStoredBriefAndPeopleWithoutRewritingStore() async throws {
        let event = ownerRuleEvent("event", body: "Example rent question?", at: now.addingTimeInterval(-1))
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: [event], checkpoint: nil))
        let original = stored([event])
        try await store.saveBrief(original)
        let core = try engine(store: store, rules: OwnerRulesFile(url: folder.appendingPathComponent("rules.json")))
        _ = await core.handle(.addKeyword(phrase: "rent", effect: .hide))
        let hidden = await core.handle(.latestBrief)
        var expected = original
        expected.brief.items = []
        XCTAssertEqual(hidden, .brief(expected))
        let people = await core.handle(.people)
        XCTAssertEqual(people, .people([]))
        _ = await core.handle(.vip(personID: "handle:sender@example.invalid", name: "Example Alex"))
        guard case let .brief(visible) = await core.handle(.latestBrief) else { return XCTFail("expected brief") }
        XCTAssertEqual(visible?.brief.items.map(\.priority), [.reply])
        guard case let .people(waiting) = await core.handle(.people) else { return XCTFail("expected people") }
        XCTAssertEqual(waiting.count, 1)
        _ = await core.handle(.addKeyword(phrase: "rent", effect: .urgent))
        guard case let .brief(urgent) = await core.handle(.latestBrief) else { return XCTFail("expected brief") }
        XCTAssertEqual(urgent?.brief.items.map(\.priority), [.urgent])
        let unchanged = try await store.latestBrief()
        XCTAssertEqual(unchanged, original)
    }

    func testGenerationCarriesVIPAndKeywordsThroughInputAndPublication() async throws {
        let vip = ownerRuleEvent(
            "vip", source: .sms, handle: "12345", body: "Your code is 000000 for rent", at: now.addingTimeInterval(-1)
        )
        let hidden = ownerRuleEvent("hidden", body: "Example crypto update", at: now.addingTimeInterval(-2))
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(
            source: .messages, status: .init(ok: true, code: .ok), events: [hidden, vip], checkpoint: nil
        ))
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        try file.save(OwnerRules(vip: ["handle:12345": "Example Alex"], keywords: [
            .init(phrase: "crypto", effect: .hide), .init(phrase: "rent", effect: .urgent),
        ]))
        let core = try engine(store: store, rules: file)
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else { return XCTFail("expected accepted") }
        await core.settle()
        let generated = try await store.latestBrief()
        XCTAssertEqual(generated?.brief.items.map(\.priority), [.urgent])
        XCTAssertEqual(generated?.brief.items.flatMap(\.eventIDs), [vip.id])
    }

    func testInterpretProposesVIPAndKeywordsWithoutApplyingCollectedRules() async throws {
        var event = ownerRuleEvent("event", body: "hide anything about rent", at: now.addingTimeInterval(-1))
        event.senderContact = .init(id: "alex", name: "Example Alex")
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: [event], checkpoint: nil))
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        let core = try engine(store: store, rules: file)
        guard case let .proposal(vip) = await core.handle(.interpret(text: "always show Example Alex")) else {
            return XCTFail("expected VIP proposal")
        }
        XCTAssertEqual(vip.action, .vip)
        XCTAssertEqual(vip.target, "contact:alex")
        _ = await core.handle(.people)
        let unchanged = await core.handle(.rules)
        XCTAssertEqual(unchanged, .rules(.empty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        _ = await core.handle(.vip(personID: vip.target, name: vip.name))
        guard case let .proposal(unvip) = await core.handle(.interpret(text: "Example Alex isn't a VIP")) else {
            return XCTFail("expected unVIP proposal")
        }
        XCTAssertEqual(unvip.action, .unvip)
        XCTAssertEqual(unvip.target, vip.target)
    }
}

private struct UnwritablePriorityRules: OwnerRulesPersistence {
    let initial: OwnerRules

    func load() throws -> OwnerRules {
        initial
    }

    func save(_: OwnerRules) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

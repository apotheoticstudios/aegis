@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineRecentEventsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_322_200)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-recent-events-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(_ events: [Event], rules: OwnerRules = .empty) async throws -> CoreEngine {
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(
            source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil
        ))
        let time = now
        return try CoreEngine(
            store: store, collectors: [], model: RecordingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model", pageSize: 2), rules: RecentEventsRules(rules: rules), clock: { time }
        )
    }

    func testNewestFirstAcrossSourcesAndStorePages() async throws {
        let oldest = ownerRuleEvent("oldest", source: .email, at: now.addingTimeInterval(-300))
        let middle = ownerRuleEvent("middle", source: .notification, at: now.addingTimeInterval(-200))
        let newest = ownerRuleEvent("newest", at: now.addingTimeInterval(-100))
        let core = try await engine([middle, newest, oldest])
        let response = await core.handle(.recentEvents(limit: 20))
        XCTAssertEqual(response, .events([newest, middle, oldest]))
    }

    func testOnlyReturnsEventsInLast24HoursUsingFixedClock() async throws {
        let beforeWindow = ownerRuleEvent("too-old", at: now.addingTimeInterval(-86401))
        let start = ownerRuleEvent("window-start", at: now.addingTimeInterval(-86400))
        let recent = ownerRuleEvent("recent", at: now.addingTimeInterval(-1))
        let future = ownerRuleEvent("future", at: now.addingTimeInterval(1))
        let core = try await engine([beforeWindow, start, recent, future])
        let response = await core.handle(.recentEvents(limit: 50))
        XCTAssertEqual(response, .events([recent, start]))
    }

    func testLimitIsAppliedToNewestEventsAndClampedToOneThroughFifty() async throws {
        let events = (1 ... 60).map { index in
            ownerRuleEvent("limit-\(index)", at: now.addingTimeInterval(-Double(index)))
        }
        let core = try await engine(events)
        let cases = [(Int.min, 1), (-5, 1), (0, 1), (1, 1), (3, 3), (50, 50), (51, 50), (Int.max, 50)]
        for (limit, count) in cases {
            let response = await core.handle(.recentEvents(limit: limit))
            XCTAssertEqual(response, .events(Array(events.prefix(count))), "limit: \(limit)")
        }
    }

    func testMutedPeopleJunkAndHiddenKeywordsAreExcludedBeforeLimit() async throws {
        var muted = ownerRuleEvent("muted", at: now.addingTimeInterval(-1))
        muted.senderContact = .init(id: "example-alex", name: "Alex Example")
        let junk = ownerRuleEvent("junk", source: .email, handle: "junk@example.invalid", at: now.addingTimeInterval(-2))
        let keyword = ownerRuleEvent("keyword", body: "Hidden example phrase", at: now.addingTimeInterval(-3))
        let visible = ownerRuleEvent("visible", at: now.addingTimeInterval(-4))
        let older = ownerRuleEvent("older-visible", at: now.addingTimeInterval(-5))
        let core = try await engine([muted, junk, keyword, visible, older], rules: OwnerRules(
            junk: ["junk@example.invalid"], muted: ["contact:example-alex": "Alex Example"],
            keywords: [.init(phrase: "hidden example", effect: .hide)]
        ))
        let response = await core.handle(.recentEvents(limit: 1))
        XCTAssertEqual(response, .events([visible]))
        let allVisible = await core.handle(.recentEvents(limit: 50))
        XCTAssertEqual(allVisible, .events([visible, older]))
    }

    func testEmptyStoreReturnsNoEventsEvenWithMinimumLimit() async throws {
        let core = try await engine([])
        let response = await core.handle(.recentEvents(limit: 0))
        XCTAssertEqual(response, .events([]))
    }
}

private struct RecentEventsRules: OwnerRulesPersistence {
    let rules: OwnerRules

    func load() throws -> OwnerRules {
        rules
    }

    func save(_: OwnerRules) throws {}
}

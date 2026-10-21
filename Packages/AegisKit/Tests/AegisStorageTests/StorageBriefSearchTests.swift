import AegisKit
@testable import AegisStorage
import Foundation
import XCTest

@MainActor
final class StorageBriefSearchTests: StorageTestCase {
    func testBriefCompletionReplacementHistoryAndReplay() async throws {
        let store = try open(history: 3)
        let empty = try await store.latestBrief()
        XCTAssertNil(empty)
        try await store.ingest(batch([event(0)]))
        let first = brief(1, citing: [event(0).id])
        try await store.saveBrief(first)
        var invalid = brief(2, citing: [event(99).id])
        do {
            try await store.saveBrief(invalid)
            XCTFail("unknown citation must fail")
        } catch { XCTAssertEqual(error as? StorageError, .incompleteBrief) }
        invalid = brief(2)
        invalid.inputRevision = ""
        do {
            try await store.saveBrief(invalid)
            XCTFail("unfinished brief must fail")
        } catch { XCTAssertEqual(error as? StorageError, .incompleteBrief) }
        let unchanged = try await store.latestBrief()
        XCTAssertEqual(unchanged, first)
        // Missing source access is valid coverage, not an unfinished generation.
        var unavailable = brief(2)
        unavailable.coverage = [.init(source: .mail, status: .permissionDenied, events: 0, lastSuccess: nil)]
        try await store.saveBrief(unavailable)
        try await store.saveBrief(brief(4))
        try await store.saveBrief(brief(3))
        try await store.saveBrief(brief(3))
        let history = try await store.briefs()
        XCTAssertEqual(history.map(\.inputRevision), ["synthetic-4", "synthetic-3", "synthetic-2"])
        let latest = try await store.latestBrief()
        XCTAssertEqual(latest, brief(4))
        let reopened = try open(history: 3)
        let persisted = try await reopened.briefs()
        XCTAssertEqual(persisted, history)
    }

    func testCitationSafeBoundedOldestFirstRetentionAndFTS() async throws {
        let store = try open(history: 2)
        try await store.ingest(batch([
            event(0, time: -30, body: "PinnedToken"),
            event(1, time: -20, body: "OldestToken"),
            event(2, time: -10, body: "OlderToken"),
            event(3, body: "NewToken"),
        ]))
        try await store.saveBrief(brief(0, citing: [event(0).id]))
        try await store.saveBrief(brief(1, citing: [event(3).id]))
        let removed = try await store.maintain(horizon: 5, now: epoch, limit: 1)
        XCTAssertEqual(removed, 1)
        var results = try await allEvents(store)
        XCTAssertEqual(Set(results.map(\.id)), Set([event(0).id, event(2).id, event(3).id]))
        let deletedSearch = try await store.events(matching: "OldestToken")
        XCTAssertTrue(deletedSearch.isEmpty)
        let pinnedSearch = try await store.events(matching: "PinnedToken")
        XCTAssertEqual(pinnedSearch.count, 1)
        _ = try await store.maintain(horizon: 5, now: epoch)
        try await store.saveBrief(brief(2)) // prunes brief 0 and releases its citations
        let released = try await store.maintain(horizon: 5, now: epoch)
        XCTAssertEqual(released, 1)
        results = try await allEvents(store)
        XCTAssertEqual(results.map(\.id), [event(3).id])
        let deletedPin = try await store.events(matching: "PinnedToken")
        XCTAssertTrue(deletedPin.isEmpty)
    }

    func testUnicodeLiteralHostileSearchFollowsEditsAndPreservesMissingEvents() async throws {
        let store = try open()
        var accented = event(0, body: "Café mañana")
        accented.title = "Résumé"
        let chinese = event(1, body: "会议改到明天上午十点")
        try await store.ingest(batch([accented, chinese, event(2, body: "Invoice Friday")]))
        let accentMatches = try await store.events(matching: "cafe manana")
        let titleMatches = try await store.events(matching: "resume")
        let chineseMatches = try await store.events(matching: "会议改到明天上午十点")
        XCTAssertEqual(accentMatches.map(\.id), [accented.id])
        XCTAssertEqual(titleMatches.map(\.id), [accented.id])
        XCTAssertEqual(chineseMatches.map(\.id), [chinese.id])
        for query in ["Robert'); DROP TABLE event;--", "\" OR 1=1; --", "title:invoice NEAR(friday)", "", "***"] {
            let matches = try await store.events(matching: query)
            XCTAssertTrue(matches.isEmpty)
        }
        var edited = accented
        edited.body = "Paid"
        edited.title = "Receipt"
        edited.captureTime = epoch.addingTimeInterval(1)
        try await store.ingest(batch([edited], scan: 1))
        let old = try await store.events(matching: "cafe")
        let oldTitle = try await store.events(matching: "resume")
        let new = try await store.events(matching: "paid")
        XCTAssertTrue(old.isEmpty)
        XCTAssertTrue(oldTitle.isEmpty)
        XCTAssertEqual(new.map(\.id), [edited.id])
        try await store.ingest(batch([chinese], scan: 2, complete: true))
        let retained = try await store.events(matching: "paid")
        XCTAssertEqual(retained.map(\.id), [edited.id])
    }
}

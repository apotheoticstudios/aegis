@testable import AegisKit
import Foundation
import XCTest

/// Items made only of junk are left out of the brief (owner's review of the test day). Synthetic only.
final class JunkItemTests: XCTestCase {
    func testJunkOnlyItemsAreLeftOutWithoutCountingAsDropped() throws {
        let base = try exampleEvents()[0]
        let sale = changed(base, "sale") { $0.source = .notification; $0.body = "SALE 50% at Example Store"; $0.title = nil }
        let ask = changed(base, "ask") { $0.body = "Can you call me?" }
        let ids = Dictionary(uniqueKeysWithValues: [sale, ask].map { ($0.id, $0) })
        let draft: [String: Any] = ["items": [
            ["text": "Example Store is running a sale.", "priority": "fyi", "event_ids": [sale.id]],
            ["text": "They asked you to call.", "priority": "reply", "event_ids": [ask.id]],
            ["text": "They asked you to call; a sale is on.", "priority": "reply", "event_ids": [ask.id, sale.id]],
        ]]
        let result = try BriefChecks.check(
            draft, input: Briefing.buildInput([sale, ask]), events: ids,
            windowStart: time("2026-10-05T21:00:00Z"), windowEnd: time("2026-10-06T21:00:00Z"), model: "test"
        ).get()
        XCTAssertEqual(result.brief.items.map(\.text), ["They asked you to call.", "Alex Example asked: “Can you call me?”"])
        XCTAssertEqual(result.droppedItems, 0)
    }
}

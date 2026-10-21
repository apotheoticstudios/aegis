@testable import AegisKit
import Foundation
import XCTest

/// Swapped speakers: a contact from one event named in an item about another (morning 1). Synthetic only.
final class BriefPeopleTests: XCTestCase {
    private func events() throws -> [Event] {
        let base = try exampleEvents()[0]
        let alex = Event.ContactRef(id: "contact-alex", name: "Alex Example")
        let sam = Event.ContactRef(id: "contact-sam", name: "Sam Example")
        return [
            changed(base, "sms-alex") {
                $0.source = .sms; $0.senderContact = alex; $0.senderHandle = "+61 400 000 111"
                $0.body = "Dinner tonight?"; $0.threadID = "thread-alex"
            },
            changed(base, "mail-promo") {
                $0.source = .email; $0.senderContact = nil; $0.senderHandle = "promo@example.com"
                $0.sender = "promo@example.com"; $0.title = "New match"; $0.body = "Someone wants to connect. Ready?"
                $0.threadID = "thread-mail"
            },
            changed(base, "mail-mentions-alex") {
                $0.source = .email; $0.senderContact = nil; $0.senderHandle = "club@example.com"
                $0.sender = "club@example.com"; $0.title = "Fixture"; $0.body = "Alex Example is captain this week."
                $0.threadID = "thread-club"
            },
            changed(base, "group-sam") {
                $0.source = .imessage; $0.senderContact = sam; $0.senderHandle = "sam@example.com"
                $0.sender = "Sam Example"; $0.title = nil; $0.body = "Bring snacks"; $0.threadID = "thread-group"
            },
            changed(base, "group-alex") {
                $0.source = .imessage; $0.senderContact = alex; $0.senderHandle = "+61 400 000 111"
                $0.body = "Running late"; $0.threadID = "thread-group"
            },
        ]
    }

    private func check(_ items: [(String, String, [String])]) throws -> CheckedBrief {
        let events = try events()
        let ids = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let byRecord = Dictionary(uniqueKeysWithValues: events.map { ($0.sourceRecordID, $0.id) })
        let draft: [String: Any] = ["items": items.map { text, priority, records in
            ["text": text, "priority": priority, "event_ids": records.compactMap { byRecord[$0] }] as [String: Any]
        }]
        return try BriefChecks.check(
            draft, input: Briefing.buildInput(events), events: ids,
            windowStart: time("2026-10-05T21:00:00Z"), windowEnd: time("2026-10-06T21:00:00Z"), model: "test"
        ).get()
    }

    func testContactAttachedToAnUnrelatedEmailIsDropped() throws {
        let result = try check([
            ("Alex Example is asking if you want to connect.", "reply", ["mail-promo"]),
            ("Alex Example asked about dinner tonight.", "reply", ["sms-alex"]),
        ])
        XCTAssertEqual(result.brief.items.map(\.text), ["Alex Example asked about dinner tonight."])
        XCTAssertEqual(result.droppedItems, 1)
    }

    func testFirstNameAsWrittenIsChecked() throws {
        let result = try check([
            ("Alex wants to connect.", "reply", ["mail-promo"]),
            ("Someone wants to connect.", "fyi", ["mail-promo"]),
        ])
        XCTAssertEqual(result.brief.items.map(\.text), ["Someone wants to connect."])
        // A lower-case word that happens to match is not a name.
        XCTAssertEqual(try check([("Alexandria trip ideas; alex is not a name here.", "fyi", ["mail-promo"])]).droppedItems, 0)
    }

    func testNamesNeedCitedEvidenceEvenWithinTheSameThread() throws {
        let result = try check([
            ("Alex Example is captain this week.", "fyi", ["mail-mentions-alex"]),
            ("Sam Example asked for snacks; Alex Example is running late.", "fyi", ["group-sam"]),
        ])
        XCTAssertEqual(result.brief.items.count, 1)
        XCTAssertEqual(result.droppedItems, 1)
    }
}

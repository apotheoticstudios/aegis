@testable import AegisKit
import Foundation
import XCTest

/// A question and the owner's answer are one brief item, never two (#212). Synthetic only.
final class AnsweredQuestionTests: XCTestCase {
    private func day() throws -> [String: Event] {
        let base = try exampleEvents()[0]
        let alex = Event.ContactRef(id: "contact-alex", name: "Alex Example")
        let asked = base.eventTime
        let list = [
            changed(base, "museum") {
                $0.source = .sms; $0.senderContact = alex; $0.body = "Do you want to go to the museum?"; $0.threadID = "SMS;-;alex"
                $0.eventTime = asked
            },
            changed(base, "yes") {
                $0.source = .sms; $0.sender = "me"; $0.direction = .outgoing; $0.senderContact = nil; $0.senderHandle = nil
                $0.body = "Yes"; $0.threadID = "SMS;-;alex"; $0.eventTime = asked.addingTimeInterval(120)
            },
            changed(base, "plan") {
                $0.source = .sms; $0.senderContact = alex; $0.body = "Can you send the plan?"; $0.threadID = "SMS;-;alex-work"
                $0.eventTime = asked.addingTimeInterval(60)
            },
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.sourceRecordID, $0) })
    }

    private func tidy(_ items: [(String, Brief.Priority, [String])]) throws -> [Brief.Item] {
        let bySource = try day()
        let byID = Dictionary(uniqueKeysWithValues: bySource.values.map { ($0.id, $0) })
        let draft = items.map { Brief.Item(text: $0.0, priority: $0.1, eventIDs: $0.2.compactMap { bySource[$0]?.id }) }
        return BriefLayout.tidy(draft, events: byID, maxUrgent: 3)
    }

    func testAQuestionAndItsAnswerStayOneItem() throws {
        let items = try tidy([("Alex Example asked about the museum and you said yes.", .reply, ["museum", "yes"])])
        XCTAssertEqual(items.count, 1, "never split into the question and the owner's reply")
        XCTAssertEqual(items.first?.eventIDs.count, 2, "both stay as its sources")
        XCTAssertEqual(items.first?.priority, .fyi, "answered: nothing waits on the owner")
    }

    func testTheOwnersOwnReplyIsNeverAnItemOfItsOwn() throws {
        let items = try tidy([
            ("Alex Example asked: “Do you want to go to the museum?”", .reply, ["museum"]),
            ("You told Alex Example yes.", .fyi, ["yes"]),
        ])
        XCTAssertEqual(items.map(\.text), ["Alex Example asked: “Do you want to go to the museum?”"])
        XCTAssertEqual(items.first?.priority, .reply, "a later reply this item doesn't cite may be unrelated: not raised, not dropped")
    }

    func testAnOpenQuestionStillNeedsAReplyAndKeepsItsAnswerWhenSplit() throws {
        let items = try tidy([("Alex Example asked two things.", .reply, ["museum", "plan", "yes"])])
        XCTAssertEqual(items.count, 2, "two questions from Alex split; the owner's reply is not a third")
        XCTAssertEqual(items.map(\.priority), [.fyi, .reply], "the museum was answered, the plan wasn't")
        let museum = try day()["museum"]?.id, yes = try day()["yes"]?.id
        XCTAssertEqual(Set(items[0].eventIDs), Set([museum, yes].compactMap(\.self)), "the answer stays with its question")
    }
}

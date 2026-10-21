@testable import AegisKit
import Foundation
import XCTest

final class CommitmentsLayoutTests: XCTestCase {
    func testRecipientContactHandleGroupAndUnknownNames() {
        let promise = CommitmentFixture.event("promise", "I'll send it tomorrow")
        var contact = CommitmentFixture.event("contact", "Example greeting")
        contact.direction = .incoming
        contact.senderHandle = "+61400000001"
        contact.senderContact = Event.ContactRef(id: "example-alex", name: "Example Alex")
        let named = CommitmentFixture.compute([promise, contact]).first
        XCTAssertEqual(named?.personID, "contact:example-alex")
        XCTAssertEqual(named?.person, "Example Alex")
        let raw = CommitmentFixture.compute([promise]).first
        XCTAssertEqual(raw?.personID, "handle:+61 400 000 001")
        XCTAssertEqual(raw?.person, "+61 400 000 001")
        var group = promise
        group.threadID = "iMessage;+;example-group"
        group.title = "  Example group\n"
        XCTAssertEqual(CommitmentFixture.compute([group, contact]).first?.personID, "group:iMessage;+;example-group")
        XCTAssertEqual(CommitmentFixture.compute([group, contact]).first?.person, "Example group")
        group.title = " \n"
        XCTAssertEqual(CommitmentFixture.compute([group]).first?.person, "Group chat")
        var unknown = promise
        unknown.recipients = []
        unknown.threadID = nil
        XCTAssertNil(CommitmentFixture.compute([unknown]).first?.personID)
        XCTAssertEqual(CommitmentFixture.compute([unknown]).first?.person, "someone")
    }

    func testFirstRecipientEmailContactAndUnknownEmail() {
        var promise = CommitmentFixture.event("mail", "I'll send it tomorrow", source: .email)
        promise.recipients = ["ALEX@example.com", "other@example.com"]
        var contact = CommitmentFixture.event("contact", "Example greeting", source: .email)
        contact.direction = .incoming
        contact.senderHandle = "alex@example.com"
        contact.senderContact = Event.ContactRef(id: "example-alex", name: "Example Alex")
        XCTAssertEqual(CommitmentFixture.compute([promise, contact]).first?.personID, "contact:example-alex")
        promise.recipients.reverse()
        XCTAssertEqual(CommitmentFixture.compute([promise, contact]).first?.personID, "handle:other@example.com")
        XCTAssertEqual(CommitmentFixture.compute([promise, contact]).first?.person, "other@example.com")
    }

    func testOrderingMaxItemsAndStableTies() {
        let events = [
            CommitmentFixture.event("undated-old", "I'll bring it", at: CommitmentFixture.date(7)),
            CommitmentFixture.event("soon", "I'll send it tomorrow", at: CommitmentFixture.date(8)),
            CommitmentFixture.event("overdue-new", "I'll send it today", at: CommitmentFixture.date(8)),
            CommitmentFixture.event("undated-new", "On it", at: CommitmentFixture.date(8)),
            CommitmentFixture.event("overdue-old", "I'll send it today", at: CommitmentFixture.date(7)),
            CommitmentFixture.event("later", "I'll send it next week", at: CommitmentFixture.date(8)),
        ]
        let now = CommitmentFixture.date(9)
        let result = CommitmentFixture.compute(events, now: now)
        XCTAssertEqual(result.map(\.eventID), [events[4], events[2], events[1], events[5], events[3], events[0]].map(\.id))
        XCTAssertEqual(CommitmentFixture.compute(Array(events.reversed()), now: now), result)
        XCTAssertEqual(CommitmentFixture.compute(events, now: now, maxItems: 2), Array(result.prefix(2)))
        XCTAssertTrue(CommitmentFixture.compute(events, now: now, maxItems: 0).isEmpty)
        XCTAssertTrue(CommitmentFixture.compute(events, now: now, maxItems: -1).isEmpty)
        let tied = [CommitmentFixture.event("tie-a", "On it"), CommitmentFixture.event("tie-b", "On it")]
        XCTAssertEqual(CommitmentFixture.compute(tied), CommitmentFixture.compute(Array(tied.reversed())))
    }
}

@testable import AegisKit
import Foundation
import XCTest

final class VIPKeywordRulesTests: XCTestCase {
    func testOldRulesDecodeWithEmptyAdditionsAndNewRulesRoundTrip() throws {
        let old = #"{"junk":["sender@example.invalid"],"trusted":[],"muted":{"group:example":"Example Group"}}"#
        let decoded = try JSONDecoder().decode(OwnerRules.self, from: Data(old.utf8))
        XCTAssertEqual(decoded, OwnerRules(junk: ["sender@example.invalid"], muted: ["group:example": "Example Group"]))
        let rules = OwnerRules(vip: ["contact:example": "Example Alex"], keywords: [.init(phrase: "rent", effect: .urgent)])
        XCTAssertEqual(try IPCCoding.decode(OwnerRules.self, from: IPCCoding.encode(rules)), rules)
        // Missing additions are backward compatible; malformed additions still fail closed.
        let invalid = #"{"junk":[],"trusted":[],"muted":{},"vip":[],"keywords":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(OwnerRules.self, from: Data(invalid.utf8)))
    }

    func testVIPValidatesLikeMuteAndLeavesOtherRulesIntact() {
        var rules = OwnerRules(muted: ["contact:example": "Example Alex"])
        XCTAssertTrue(rules.prioritise("contact:example", name: "  Example Alex\n"))
        XCTAssertEqual(rules.vip, ["contact:example": "Example Alex"])
        XCTAssertEqual(rules.muted, rules.vip)
        let previous = rules
        for id in ["", "person:example", "contact:", "group: \n", "handle:"] {
            XCTAssertFalse(rules.prioritise(id, name: "Example"))
            XCTAssertFalse(rules.unprioritise(id))
            XCTAssertEqual(rules, previous)
        }
        for name in [" \n", String(repeating: "e\u{301}", count: 61)] {
            XCTAssertFalse(rules.prioritise("contact:example", name: name))
            XCTAssertEqual(rules, previous)
        }
        XCTAssertTrue(rules.unprioritise("contact:example"))
        XCTAssertTrue(rules.unprioritise("contact:example"))
        XCTAssertTrue(rules.vip.isEmpty)
        XCTAssertEqual(rules.muted, previous.muted)
    }

    func testKeywordValidationReplacementRemovalAndFiftyRuleLimit() {
        var rules = OwnerRules.empty
        for phrase in ["", " \n", "a", String(repeating: "e\u{301}", count: 31)] {
            XCTAssertFalse(rules.addKeyword(phrase, effect: .urgent))
            XCTAssertFalse(rules.removeKeyword(phrase))
            XCTAssertEqual(rules, .empty)
        }
        XCTAssertTrue(rules.addKeyword("  Rent\n", effect: .urgent))
        XCTAssertEqual(rules.keywords, [.init(phrase: "Rent", effect: .urgent)])
        XCTAssertTrue(rules.addKeyword("RENT", effect: .hide))
        XCTAssertEqual(rules.keywords, [.init(phrase: "RENT", effect: .hide)])
        XCTAssertTrue(rules.removeKeyword(" rent "))
        XCTAssertTrue(rules.removeKeyword("rent"))
        XCTAssertTrue(rules.addKeyword(String(repeating: "e\u{301}", count: 30), effect: .urgent))
        for index in 1 ..< 50 {
            XCTAssertTrue(rules.addKeyword("example \(index)", effect: .hide))
        }
        let previous = rules
        XCTAssertFalse(rules.addKeyword("another example", effect: .hide))
        XCTAssertEqual(rules, previous)
        XCTAssertTrue(rules.addKeyword("EXAMPLE 1", effect: .urgent))
        XCTAssertEqual(rules.keywords.count, 50)
    }

    func testKeywordsAreLiteralCaseInsensitiveWholeWordsInIncomingBodyOrTitle() {
        let rule = KeywordRule(phrase: "rent", effect: .urgent)
        for body in ["RENT", "Example rent?", "(rent)", "rent-free"] {
            XCTAssertTrue(rule.matches(ownerRuleEvent("match", body: body)), body)
        }
        for body in ["rental", "parent", "rent2", "rent_owed", "renté", "rent\u{301}"] {
            XCTAssertFalse(rule.matches(ownerRuleEvent("miss", body: body)), body)
        }
        var event = ownerRuleEvent("title", source: .email, body: "Example update")
        event.title = "Rent: Example invoice"
        XCTAssertTrue(rule.matches(event))
        event.direction = .outgoing
        XCTAssertFalse(rule.matches(event))
        let literal = KeywordRule(phrase: "a+b", effect: .hide)
        XCTAssertTrue(literal.matches(ownerRuleEvent("literal", body: "Example a+b.")))
        XCTAssertFalse(literal.matches(ownerRuleEvent("regex", body: "Example aaab.")))
        XCTAssertTrue(KeywordRule(phrase: "example rent", effect: .hide).matches(
            ownerRuleEvent("phrase", body: "The EXAMPLE RENT is due.")
        ))
    }

    func testHideExemptsVIPButMuteAndJunkBeatVIP() {
        let event = ownerRuleEvent("incoming", body: "Example crypto question?")
        let person = "handle:sender@example.invalid"
        var rules = OwnerRules(keywords: [.init(phrase: "crypto", effect: .hide)])
        XCTAssertEqual(rules.hide(event, contacts: [:]), .keyword)
        XCTAssertEqual(rules.visible([event]), [])
        XCTAssertTrue(rules.prioritise(person, name: "Example Alex"))
        XCTAssertNil(rules.hide(event, contacts: [:]))
        XCTAssertEqual(rules.visible([event]), [event])
        XCTAssertTrue(rules.mute(person, name: "Example Alex"))
        XCTAssertEqual(rules.hide(event, contacts: [:]), .muted)
        XCTAssertTrue(rules.unmute(person))
        XCTAssertTrue(rules.markJunk("sender@example.invalid"))
        XCTAssertEqual(rules.hide(event, contacts: [:]), .junk)
        var sent = event
        sent.direction = .outgoing
        sent.sender = "me"
        XCTAssertNil(rules.hide(sent, contacts: [:]))
    }

    func testVIPUsesContactAndGroupIdentitiesAndFilteredStillShowsExplicitJunk() {
        var chat = ownerRuleEvent("chat", body: "Your code is 000000")
        chat.senderContact = .init(id: "example", name: "Example Alex")
        var notice = ownerRuleEvent("notice", source: .notification, body: chat.body)
        notice.senderHandle = nil
        notice.appID = "com.apple.MobileSMS"
        notice.title = "Example Alex"
        let rules = OwnerRules(vip: ["contact:example": "Example Alex"])
        let contacts = BriefLayout.contactIDs([chat.id: chat, notice.id: notice])
        XCTAssertTrue(rules.isVIP(chat, contacts: contacts))
        XCTAssertTrue(rules.isVIP(notice, contacts: contacts))
        XCTAssertTrue(Filtered.compute(events: [chat, notice], rules: rules, maxSenders: 20).isEmpty)
        var junk = rules
        XCTAssertTrue(junk.markJunk("sender@example.invalid"))
        XCTAssertEqual(Filtered.compute(events: [chat], rules: junk, maxSenders: 20).map(\.reason), [.markedJunk])
        chat.threadID = "iMessage;+;example"
        XCTAssertFalse(rules.isVIP(chat, contacts: contacts), "a member's VIP does not prioritise their group")
        XCTAssertTrue(OwnerRules(vip: ["group:iMessage;+;example": "Example Group"]).isVIP(chat))
    }

    func testKeywordHideRemovesPeopleWaitingExceptVIPAndNeverHidesOutgoing() {
        let hidden = ownerRuleEvent("hidden", body: "Example crypto question?")
        let visible = ownerRuleEvent("visible", handle: "other@example.invalid", body: "Example crypto question?")
        var sent = ownerRuleEvent("sent", body: "Example crypto reply")
        sent.direction = .outgoing
        sent.sender = "me"
        let rules = OwnerRules(
            vip: ["handle:other@example.invalid": "Example Other"], keywords: [.init(phrase: "crypto", effect: .hide)]
        )
        XCTAssertEqual(rules.visible([hidden, visible, sent]), [visible, sent])
        let rows = PeopleWaiting.compute(events: rules.visible([hidden, visible]), now: visible.eventTime, maxPeople: 12)
        XCTAssertEqual(rows.map(\.person.id), ["handle:other@example.invalid"])
    }
}

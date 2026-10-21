@testable import AegisKit
import Foundation
import XCTest

final class OwnerRulesTests: XCTestCase {
    func testJunkUsesIncomingSenderOrNotificationAppIdentity() {
        let mail = ownerRuleEvent("mail", source: .email, handle: " SENDER@example.invalid ")
        var notice = ownerRuleEvent("notice", source: .notification)
        notice.senderHandle = nil
        notice.appID = "invalid.example.app"
        var rules = OwnerRules.empty
        XCTAssertTrue(rules.markJunk("sender@example.invalid"))
        XCTAssertTrue(rules.markJunk("INVALID.EXAMPLE.APP"))
        XCTAssertEqual(rules.hide(mail, contacts: [:]), .junk)
        XCTAssertEqual(rules.hide(notice, contacts: [:]), .junk)
        var sent = mail
        sent.direction = .outgoing
        sent.sender = "me"
        XCTAssertNil(rules.hide(sent, contacts: [:]))
        notice.senderHandle = "other@example.invalid"
        XCTAssertNil(rules.hide(notice, contacts: [:]), "a handle takes precedence over the app ID")
        notice.senderHandle = nil
        notice.appID = nil
        XCTAssertNil(rules.hide(notice, contacts: [:]))
    }

    func testNotJunkRemovesJunkAndBypassesAutomaticNoise() throws {
        var mail = ownerRuleEvent("mail", source: .email, body: "Your code is 000000")
        mail.flags = [.bulk]
        var rules = OwnerRules.empty
        XCTAssertTrue(rules.markJunk("sender@example.invalid"))
        XCTAssertTrue(rules.notJunk(" SENDER@example.invalid \n"))
        XCTAssertTrue(rules.junk.isEmpty)
        XCTAssertEqual(rules.trusted, ["sender@example.invalid"])
        XCTAssertNil(rules.hide(mail, contacts: [:]))
        XCTAssertNil(NoiseRules.reason(mail, trusted: rules.trusted))
        let input = try BriefInputPolicy(
            windowStart: mail.eventTime.addingTimeInterval(-1), windowEnd: mail.eventTime.addingTimeInterval(1),
            trustedSenders: rules.trusted
        ).build(rules.visible([mail]))
        XCTAssertEqual(input.eventIDs, [mail.id])
        XCTAssertTrue(rules.markJunk("sender@example.invalid"))
        XCTAssertTrue(rules.trusted.isEmpty)
        XCTAssertEqual(rules.hide(mail, contacts: [:]), .junk)
    }

    func testMutedGroupHidesBothDirectionsButNotMembersDirectChats() {
        var incoming = ownerRuleEvent("incoming")
        incoming.threadID = "iMessage;+;example-group"
        var outgoing = ownerRuleEvent("outgoing")
        outgoing.threadID = incoming.threadID
        outgoing.direction = .outgoing
        outgoing.sender = "me"
        let direct = ownerRuleEvent("direct")
        var rules = OwnerRules.empty
        XCTAssertTrue(rules.mute("group:iMessage;+;example-group", name: "  Example Group\n"))
        XCTAssertEqual(rules.muted["group:iMessage;+;example-group"], "Example Group")
        XCTAssertEqual(rules.hide(incoming, contacts: [:]), .muted)
        XCTAssertEqual(rules.hide(outgoing, contacts: [:]), .muted)
        XCTAssertNil(rules.hide(direct, contacts: [:]))
        XCTAssertEqual(rules.visible([outgoing, direct, incoming]), [direct])
        XCTAssertTrue(rules.unmute("group:iMessage;+;example-group"))
        XCTAssertEqual(rules.visible([outgoing, direct, incoming]), [outgoing, direct, incoming])
    }

    func testContactMuteCoversAllMatchedHandlesAndNamedNotifications() {
        let contact = Event.ContactRef(id: "example-contact", name: "Example Contact")
        var chat = ownerRuleEvent("chat")
        chat.senderContact = contact
        var mail = ownerRuleEvent("mail", source: .email, handle: "other@example.invalid")
        mail.senderContact = contact
        var notice = ownerRuleEvent("notice", source: .notification)
        notice.appID = "com.apple.MobileSMS"
        notice.senderHandle = nil
        notice.title = contact.name
        let other = ownerRuleEvent("other", handle: "third@example.invalid")
        var rules = OwnerRules.empty
        XCTAssertTrue(rules.mute("contact:example-contact", name: contact.name))
        XCTAssertEqual(rules.visible([notice, chat, other, mail]), [other])
        XCTAssertTrue(rules.unmute("contact:example-contact"))
        XCTAssertEqual(rules.visible([notice, chat, other, mail]), [notice, chat, other, mail])
    }

    func testHandleMuteAndBadInputLeaveRulesUnchanged() {
        let chat = ownerRuleEvent("chat")
        var rules = OwnerRules.empty
        XCTAssertTrue(rules.mute("handle:sender@example.invalid", name: "Example"))
        XCTAssertEqual(rules.hide(chat, contacts: [:]), .muted)
        XCTAssertTrue(rules.unmute("handle:sender@example.invalid"))
        XCTAssertNil(rules.hide(chat, contacts: [:]))
        let before = rules
        for handle in ["", " \n\t", String(repeating: "e\u{301}", count: 161)] {
            XCTAssertFalse(rules.markJunk(handle))
            XCTAssertFalse(rules.notJunk(handle))
            XCTAssertEqual(rules, before)
        }
        for id in ["", "person:example", "contact:", "group: \n", "handle:"] {
            XCTAssertFalse(rules.mute(id, name: "Example"))
            XCTAssertFalse(rules.unmute(id))
            XCTAssertEqual(rules, before)
        }
        for name in [" \n", String(repeating: "e\u{301}", count: 61)] {
            XCTAssertFalse(rules.mute("contact:example", name: name))
            XCTAssertEqual(rules, before)
        }
        XCTAssertTrue(rules.markJunk(String(repeating: "a", count: 320)))
        XCTAssertTrue(rules.mute("contact:example", name: String(repeating: "e\u{301}", count: 60)))
    }

    func testFilteredListsExplicitJunkButNeverTrustedOrMuted() throws {
        let ordinary = ownerRuleEvent("ordinary", source: .email, body: "Example update")
        let outgoing = ownerRuleEvent("outgoing", source: .email, body: "Example reply")
        var sent = outgoing
        sent.direction = .outgoing
        sent.sender = "me"
        var rules = OwnerRules(junk: ["sender@example.invalid"])
        XCTAssertNil(NoiseRules.reason(ordinary))
        let row = try XCTUnwrap(Filtered.compute(events: [ordinary, sent], rules: rules, maxSenders: 20).first)
        XCTAssertEqual(row.reason, .markedJunk)
        XCTAssertEqual(row.eventIDs, [ordinary.id])
        XCTAssertEqual(row.count, 1)
        rules.trusted.insert("sender@example.invalid")
        XCTAssertTrue(Filtered.compute(events: [ordinary], rules: rules, maxSenders: 20).isEmpty)
        rules.trusted = []
        var chat = ownerRuleEvent("chat", body: "Your code is 000000")
        XCTAssertTrue(rules.mute("handle:sender@example.invalid", name: "Example"))
        XCTAssertTrue(Filtered.compute(events: [chat], rules: rules, maxSenders: 20).isEmpty)
        rules.junk = []
        chat.source = .sms
        XCTAssertTrue(Filtered.compute(events: [chat], rules: rules, maxSenders: 20).isEmpty)
    }

    func testFilteredListsMarkedNotificationAppsAndSuppressesMutedContacts() throws {
        var notice = ownerRuleEvent("notice", source: .notification, body: "Example app update")
        notice.senderHandle = nil
        notice.appID = "invalid.example.app"
        let rules = OwnerRules(junk: ["invalid.example.app"])
        let row = try XCTUnwrap(Filtered.compute(events: [notice], rules: rules, maxSenders: 20).first)
        XCTAssertEqual(row.handle, "invalid.example.app")
        XCTAssertEqual(row.reason, .markedJunk)
        var chat = ownerRuleEvent("chat", body: "Your code is 000000")
        chat.senderContact = .init(id: "example-contact", name: "Example Contact")
        let muted = OwnerRules(junk: ["sender@example.invalid"], muted: ["contact:example-contact": "Example Contact"])
        XCTAssertTrue(Filtered.compute(events: [chat], rules: muted, maxSenders: 20).isEmpty)
    }
}

final class OwnerRulesFileTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-rules-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTripAndStableSortedOutput() throws {
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        XCTAssertEqual(try file.load(), .empty)
        let rules = OwnerRules(junk: ["z", "a"], trusted: ["y", "b"], muted: ["group:z": "Z", "contact:a": "A"])
        try file.save(rules)
        XCTAssertEqual(try file.load(), rules)
        let bytes = try Data(contentsOf: file.url)
        XCTAssertEqual(
            try XCTUnwrap(String(data: bytes, encoding: .utf8)),
            #"{"junk":["a","z"],"keywords":[],"muted":{"contact:a":"A","group:z":"Z"},"trusted":["b","y"],"vip":{}}"#
        )
        try file.save(OwnerRules(junk: ["a", "z"], trusted: ["b", "y"], muted: ["contact:a": "A", "group:z": "Z"]))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testLegacyMigrationOnlyWhenRulesFileIsAbsent() throws {
        let legacy = TrustedSendersFile(url: folder.appendingPathComponent("trusted-senders.json"))
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"), legacyTrusted: legacy.url)
        XCTAssertEqual(try file.load(), .empty)
        try legacy.save(["sender@example.invalid"])
        XCTAssertEqual(try file.load(), OwnerRules(trusted: ["sender@example.invalid"]))
        try file.save(OwnerRules(junk: ["other@example.invalid"]))
        XCTAssertEqual(try file.load(), OwnerRules(junk: ["other@example.invalid"]))
        XCTAssertEqual(try legacy.load(), ["sender@example.invalid"])
        try Data("invalid JSON".utf8).write(to: file.url)
        XCTAssertThrowsError(try file.load(), "a corrupt rules file must not fall back to legacy trust")
    }
}

/// Synthetic events shared by the owner-rules unit and engine tests.
func ownerRuleEvent(
    _ id: String, source: Event.Source = .imessage, handle: String = "sender@example.invalid",
    body: String = "Can you confirm the example?", at date: Date = Date(timeIntervalSince1970: 10000)
) -> Event {
    Event(
        source: source, sourceRecordID: id, appID: nil, sender: handle, threadID: id,
        eventTime: date, eventTimeSource: .received, captureTime: date, title: nil, body: body, content: .complete,
        observations: [.init(
            route: source == .notification ? .notificationDB : (source == .email ? .mailStore : .chatDB),
            sourceRecordID: id, captureTime: date
        )], senderHandle: handle
    )
}

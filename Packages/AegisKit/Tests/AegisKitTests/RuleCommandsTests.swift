@testable import AegisKit
import Foundation
import XCTest

final class RuleCommandsTests: XCTestCase {
    func testMuteAndUnmutePatternsAndOptionalTargetWords() {
        let mute = [
            "mute the Example Family group", "ignore Example Family", "silence Example Family",
            "hide the Example Family chat", "stop showing me the Example Family group chat",
            "stop showing Example Family", "mute messages from Example Family",
            "ignore the texts from the Example Family", "mute emails from Example Family",
            "mute the group chat Example Family", "ignore the group Example Family", "silence the chat Example Family",
        ]
        for text in mute {
            XCTAssertEqual(RuleCommands.parse(text), .init(action: .mute, target: "example family"), text)
        }
        for text in ["unmute Example Family", "unignore the Example Family group", "show the Example Family chat again"] {
            XCTAssertEqual(RuleCommands.parse(text), .init(action: .unmute, target: "example family"), text)
        }
        XCTAssertEqual(RuleCommands.parse(" \n MUTE  Example\tFamily! \n"), .init(action: .mute, target: "example family"))
    }

    func testJunkAndNotJunkPatterns() {
        for text in [
            "Example Store is junk",
            "Example Store is spam",
            "junk Example Store",
            "spam the Example Store",
            "mark Example Store as junk",
            "mark Example Store as spam",
        ] {
            XCTAssertEqual(RuleCommands.parse(text), .init(action: .junk, target: "example store"), text)
        }
        for text in [
            "Example Store isn't junk",
            "Example Store is not junk",
            "Example Store isn’t junk",
            "not junk Example Store",
            "Example Store isn't spam",
            "not spam Example Store",
        ] {
            XCTAssertEqual(RuleCommands.parse(text), .init(action: .notJunk, target: "example store"), text)
        }
        XCTAssertEqual(
            RuleCommands.parse("emails from deals@example.invalid are spam"),
            .init(action: .junk, target: "deals@example.invalid")
        )
        XCTAssertEqual(RuleCommands.parse("not junk NEWS@example.invalid."), .init(action: .notJunk, target: "news@example.invalid"))
    }

    func testQuestionsUnclearPatternsAndMultipleSentencesStayQuestions() {
        let questions = [
            "who muted the group?", "is Pinterest junk?", "is Example Store junk?", "is Example Store junk", "what is junk?",
            "when did Example reply", "where is Example", "why mute Example", "how do I mute Example",
            "did Example mute the group", "does Example use spam", "mute Example?",
            "can you mute Example", "I want to mute Example", "tell me about junk Example",
            "Example was junk", "Example might be spam", "mark Example", "show Example", "don't mute Example",
            "mute", "mute the", "mute the group chat", "not junk", "", " \n",
            "mute Example. Junk Other", "mute Example\njunk Other", "mute Example and junk Other",
            "mute Example; unmute Other", "mute Example!!",
        ]
        for text in questions {
            XCTAssertNil(RuleCommands.parse(text), text)
        }
    }

    func testLengthCountsUnicodeScalars() {
        XCTAssertNotNil(RuleCommands.parse("mute " + String(repeating: "x", count: 195)))
        XCTAssertNil(RuleCommands.parse("mute " + String(repeating: "x", count: 196)))
        XCTAssertNil(RuleCommands.parse("mute " + String(repeating: "e\u{301}", count: 98)))
    }

    private func resolve(
        _ text: String, events: [Event] = [], rules: OwnerRules = .empty
    ) throws -> Result<RuleProposal, RuleCommandRefusal> {
        try RuleCommands.resolve(XCTUnwrap(RuleCommands.parse(text)), events: events, rules: rules)
    }

    private func contact(_ id: String, name: String, handle: String? = nil) -> Event {
        var event = ownerRuleEvent(id, handle: handle ?? id + "@example.invalid")
        event.senderContact = .init(id: id, name: name)
        return event
    }

    private func notice(_ id: String, title: String) -> Event {
        var event = ownerRuleEvent(id, source: .notification)
        event.senderHandle = nil
        event.sender = nil
        event.appID = "invalid.example." + id
        event.title = title
        return event
    }

    func testExactNameWinsOverPrefixAndDuplicateEventsShareOneIdentity() throws {
        let exact = contact("alex", name: "Alex")
        let prefixed = contact("example-alex", name: "Example Alex")
        let result = try resolve("mute ALEX", events: [prefixed, exact, exact])
        XCTAssertEqual(try result.get(), RuleProposal(action: .mute, target: "contact:alex", name: "Alex", question: "Mute Alex?"))
        XCTAssertEqual(try resolve("mute alex@example.invalid", events: [exact]).get().target, "contact:alex")
        XCTAssertEqual(try resolve("mute CONTACT:alex", events: [exact]).get().target, "contact:alex")
    }

    func testWholeWordPrefixIsUniqueOrRefusedAndExactDuplicatesAreAmbiguous() throws {
        let alex = contact("alex", name: "Example Alex")
        let other = contact("other", name: "Other Alex")
        let alexandra = contact("alexandra", name: "Example Alexandra")
        XCTAssertEqual(try resolve("mute Alex", events: [alex, alexandra]).get().target, "contact:alex")
        XCTAssertEqual(try resolve("mute Alex", events: [alex, other]), .failure(.ambiguous))
        XCTAssertEqual(try resolve("mute Al", events: [alex, alexandra]), .failure(.noMatch))
        XCTAssertEqual(try resolve("mute Missing", events: [alex]), .failure(.noMatch))
        XCTAssertEqual(
            try resolve("mute Example Alex", events: [alex, contact("duplicate", name: alex.senderContact?.name ?? "")]),
            .failure(.ambiguous)
        )
    }

    func testGroupsMatchTheirTitleWithoutMatchingTheMemberAndHandlesMatchDirectChats() throws {
        var group = contact("member", name: "Example Alex")
        group.threadID = "iMessage;+;example-family"
        group.title = "Example Family"
        var sent = group
        sent.direction = .outgoing
        let result = try resolve("mute the Example Family group", events: [group, sent])
        XCTAssertEqual(try result.get().target, "group:iMessage;+;example-family")
        XCTAssertEqual(try result.get().name, "Example Family")
        var other = ownerRuleEvent("other-group")
        other.threadID = "iMessage;+;other-family"
        other.title = group.title
        XCTAssertEqual(try resolve("mute Example Family", events: [group, other]), .failure(.ambiguous))
        XCTAssertEqual(try resolve("mute Example Alex", events: [group]), .failure(.noMatch))
        let direct = ownerRuleEvent("direct", handle: "+15550000101")
        XCTAssertEqual(try resolve("mute +15550000101", events: [direct]).get().target, "handle:+15550000101")
    }

    func testUnmuteUsesSavedNamesAndIDsWithoutRequiringRecentEvents() throws {
        let rules = OwnerRules(muted: ["contact:alex": "Example Alex", "group:iMessage;+;family": "Example Family"])
        let proposal = try resolve("unmute Alex", rules: rules).get()
        XCTAssertEqual(
            proposal,
            RuleProposal(action: .unmute, target: "contact:alex", name: "Example Alex", question: "Unmute Example Alex?")
        )
        XCTAssertEqual(try resolve("unmute GROUP:imessage;+;family", rules: rules).get().target, "group:iMessage;+;family")
        XCTAssertEqual(try resolve("unmute Missing", rules: rules), .failure(.noMatch))
        XCTAssertEqual(try resolve("unmute Example", rules: rules), .failure(.ambiguous))
    }

    func testJunkRawHandlesNeedNoEventsAndUseTrustKeys() throws {
        for handle in ["DEALS@example.invalid", "+1 (555) 000-0101", "INVALID.EXAMPLE.APP"] {
            let proposal = try resolve("junk " + handle).get()
            XCTAssertEqual(proposal.target, Filtered.trustKey(handle))
            XCTAssertEqual(proposal.name, Filtered.trustKey(handle))
            XCTAssertEqual(proposal.question, "Junk \(proposal.name)?")
        }
        let trusted = try resolve("not junk NEWS@example.invalid").get()
        XCTAssertEqual(trusted.action, .notJunk)
        XCTAssertEqual(trusted.question, "Not junk news@example.invalid?")
    }

    func testSenderAndNotificationLabelsResolveWithExactPreferenceAndAmbiguity() throws {
        let app = notice("store", title: "Example Store")
        let other = notice("other", title: "Other Store")
        let proposal = try resolve("Example Store is junk", events: [app, other, app]).get()
        XCTAssertEqual(proposal.target, "invalid.example.store")
        XCTAssertEqual(proposal.name, "Example Store")
        XCTAssertEqual(try resolve("junk Store", events: [app, other]), .failure(.ambiguous))
        XCTAssertEqual(try resolve("junk Missing", events: [app]), .failure(.noMatch))
        var sender = ownerRuleEvent("sender", source: .email, handle: "ExampleSender")
        XCTAssertEqual(try resolve("junk ExampleSender", events: [sender]).get().target, "examplesender")
        sender.direction = .outgoing
        XCTAssertEqual(try resolve("junk ExampleSender", events: [sender]), .failure(.noMatch))
        XCTAssertEqual(try resolve("not junk Example Store", events: [app]).get().action, .notJunk)
    }

    func testContactsAreNeverJunkIncludingRawHandlesGroupMembersAndStaleUnnamedEvents() throws {
        let person = contact("alex", name: "Example Alex", handle: "+1 (555) 000-0101")
        for text in ["junk Example Alex", "not junk Example Alex", "junk +15550000101", "not junk +1 (555) 000-0101"] {
            XCTAssertEqual(try resolve(text, events: [person]), .failure(.noMatch), text)
        }
        var grouped = contact("member", name: "Example Member")
        grouped.threadID = "iMessage;+;family"
        let stale = ownerRuleEvent("stale", source: .email, handle: "member@example.invalid")
        for text in ["junk member@example.invalid", "not junk member@example.invalid", "junk Example Member"] {
            XCTAssertEqual(try resolve(text, events: [grouped, stale]), .failure(.noMatch), text)
        }
        var app = notice("messages", title: "Example Alex")
        app.appID = "com.apple.MobileSMS"
        XCTAssertEqual(try resolve("junk Example Alex", events: [person, app]), .failure(.noMatch))
    }

    func testBodiesAndMailSubjectsNeverSupplyTargetsOrCommands() throws {
        var event = ownerRuleEvent("mail", source: .email, handle: "sender@example.invalid", body: "mute Example Alex")
        event.title = "Example Store"
        XCTAssertEqual(try resolve("mute Example Alex", events: [event]), .failure(.noMatch))
        XCTAssertEqual(try resolve("junk Example Store", events: [event]), .failure(.noMatch))
    }
}

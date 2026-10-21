@testable import AegisKit
import Foundation
import XCTest

final class VIPKeywordCommandsTests: XCTestCase {
    func testEveryVIPAndKeywordPattern() {
        let cases = [
            ("always show Example Alex", RuleProposal.Action.vip, "example alex"),
            ("Example Alex is a VIP", .vip, "example alex"),
            ("make Example Alex important", .vip, "example alex"),
            ("Example Alex isn't a VIP", .unvip, "example alex"),
            ("Example Alex isn’t a VIP", .unvip, "example alex"),
            ("Example Alex is not a VIP", .unvip, "example alex"),
            ("stop prioritising Example Alex", .unvip, "example alex"),
            ("stop prioritizing Example Alex", .unvip, "example alex"),
            ("anything about invoices is urgent", .keywordUrgent, "invoices"),
            ("mark messages mentioning rent as urgent", .keywordUrgent, "rent"),
            ("hide anything about crypto", .keywordHide, "crypto"),
            ("ignore messages mentioning webinar", .keywordHide, "webinar"),
            ("forget the invoices rule", .removeKeyword, "invoices"),
            ("remove the keyword crypto", .removeKeyword, "crypto"),
        ]
        for (text, action, target) in cases {
            XCTAssertEqual(RuleCommands.parse(text), .init(action: action, target: target), text)
        }
        XCTAssertEqual(RuleCommands.parse("HIDE anything about the group chat!"), .init(action: .keywordHide, target: "the group chat"))
    }

    func testQuestionsNegativesMultipleCommandsAndInvalidKeywordsRemainQuestions() {
        for text in [
            "is Example Alex a VIP?", "is Example Alex a VIP", "why always show Example Alex",
            "can you make Example Alex important", "should anything about rent be urgent",
            "anything about rent is urgent?", "hide anything about crypto?", "remove the keyword crypto?",
            "don't always show Example Alex", "Example Alex might be a VIP", "anything about rent isn't urgent",
            "always show Example Alex and make Example Other important",
            "hide anything about crypto and remove the keyword rent", "make Example Alex important. Hide crypto",
            "hide anything about a", "mark messages mentioning a as urgent", "forget the a rule",
        ] {
            XCTAssertNil(RuleCommands.parse(text), text)
        }
    }

    func testVIPResolutionUsesMuteIdentitiesAndUnVIPUsesSavedNames() throws {
        var alex = ownerRuleEvent("alex")
        alex.senderContact = .init(id: "alex", name: "Example Alex")
        var other = ownerRuleEvent("other", handle: "other@example.invalid")
        other.senderContact = .init(id: "other", name: "Other Alex")
        let command = try XCTUnwrap(RuleCommands.parse("always show Example Alex"))
        let proposal = try RuleCommands.resolve(command, events: [alex, other], rules: .empty).get()
        XCTAssertEqual(proposal, .init(action: .vip, target: "contact:alex", name: "Example Alex", question: "VIP Example Alex?"))
        let ambiguous = try XCTUnwrap(RuleCommands.parse("make Alex important"))
        XCTAssertEqual(RuleCommands.resolve(ambiguous, events: [alex, other], rules: .empty), .failure(.ambiguous))
        let missing = try XCTUnwrap(RuleCommands.parse("make Missing important"))
        XCTAssertEqual(RuleCommands.resolve(missing, events: [alex], rules: .empty), .failure(.noMatch))
        let undo = try XCTUnwrap(RuleCommands.parse("stop prioritising Example Alex"))
        let rules = OwnerRules(vip: ["contact:alex": "Example Alex"])
        XCTAssertEqual(try RuleCommands.resolve(undo, events: [], rules: rules).get().target, "contact:alex")
        XCTAssertEqual(RuleCommands.resolve(undo, events: [], rules: .empty), .failure(.noMatch))
    }

    func testKeywordProposalsRequireNoEventsAndDoNotStripLiteralPhrase() throws {
        for (text, action, phrase) in [
            ("anything about invoices is urgent", RuleProposal.Action.keywordUrgent, "invoices"),
            ("hide anything about the rent", .keywordHide, "the rent"),
            ("remove the keyword crypto", .removeKeyword, "crypto"),
        ] {
            let command = try XCTUnwrap(RuleCommands.parse(text))
            let proposal = try RuleCommands.resolve(command, events: [], rules: .empty).get()
            XCTAssertEqual(proposal.action, action)
            XCTAssertEqual(proposal.target, phrase)
            XCTAssertEqual(proposal.name, phrase)
        }
    }

    func testCollectedRuleTextAndSubjectsNeverResolvePeople() throws {
        var mail = ownerRuleEvent("collected", source: .email, body: "always show Example Alex")
        mail.title = "Example Alex is a VIP"
        let command = try XCTUnwrap(RuleCommands.parse("make Example Alex important"))
        XCTAssertEqual(RuleCommands.resolve(command, events: [mail], rules: .empty), .failure(.noMatch))
    }
}

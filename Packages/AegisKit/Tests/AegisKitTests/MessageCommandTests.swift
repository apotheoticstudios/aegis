@testable import AegisKit
import XCTest

final class MessageCommandTests: XCTestCase {
    func testTextsAreDraftsUnlessTheOwnerSaysSend() throws {
        let draft = try XCTUnwrap(MessageCommand.parse("Text Example Sam I'm running late"))
        XCTAssertEqual(draft.channel, .message)
        XCTAssertFalse(draft.send)
        XCTAssertEqual(draft.candidates.map(\.name), ["Example Sam I'm", "Example Sam", "Example"], "longest name first")
        XCTAssertEqual(draft.candidates[1].body, "I'm running late")
        let send = try XCTUnwrap(MessageCommand.parse("hey aegis, message Mum saying I'll call tonight and send it"))
        XCTAssertTrue(send.send)
        XCTAssertEqual(send.candidates, [.init(name: "Mum", body: "I'll call tonight")])
        let phrased = try XCTUnwrap(MessageCommand.parse("send Example Alex a text saying see you at 6"))
        XCTAssertEqual(phrased.candidates, [.init(name: "Example Alex", body: "See you at 6")])
        XCTAssertFalse(phrased.send, "'send … a text' is phrasing, not a request to send it")
    }

    func testEmailsHaveSubjects() throws {
        let email = try XCTUnwrap(MessageCommand.parse("Email Example Alex about Friday saying the venue changed, send it now"))
        XCTAssertEqual(email.channel, .email)
        XCTAssertEqual(email.subject, "Friday")
        XCTAssertTrue(email.send)
        XCTAssertEqual(email.candidates, [.init(name: "Example Alex", body: "The venue changed")])
    }

    func testOtherLinesArentMessages() {
        for line in ["tell me a joke", "What did Sam text me?", "message me later", "Remind me to text Sam"] {
            XCTAssertNil(MessageCommand.parse(line), line)
        }
    }

    func testSendingNeedsTwoConfirmationsAndDraftsDont() {
        let send = ActionPayload.message(recipientHandle: "+61400000001", text: "Running late", channel: .message, verb: .send)
        let draft = ActionPayload.message(recipientHandle: "+61400000001", text: "Running late", channel: .message, verb: .open)
        let tier = { (payload: ActionPayload) in
            ActionPolicy.decision(for: ActionRequest(payload: payload, origin: .ownerSpoken), settings: .init(panelIsOpen: true)).tier
        }
        XCTAssertEqual(tier(send), .confirmTwice)
        XCTAssertEqual(tier(draft), .auto)
    }
}

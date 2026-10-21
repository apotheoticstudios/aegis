@testable import AegisKit
import Foundation
import XCTest

final class CommitmentsDetectionTests: XCTestCase {
    func testEveryFuturePrefixAndOptionalModifier() {
        for prefix in ["I'll", "I will", "Ill", "I'm going to", "I am going to", "I’ll"] {
            for modifier in ["", "just ", "definitely ", "def ", "also ", "then "] {
                let text = prefix + " " + modifier + "send the report tomorrow."
                let result = CommitmentFixture.compute([CommitmentFixture.event("promise", text)])
                XCTAssertEqual(result.map(\.text), [text], text)
            }
        }
    }

    func testEveryActionAndShortPromiseForm() {
        let actions = [
            "send", "email", "text", "message", "call", "ring", "pay", "transfer", "book", "bring", "pick up", "drop off",
            "check", "look into", "look at", "get back to", "let you know", "fix", "finish", "sort", "sort out", "confirm",
            "review", "share", "forward", "organise", "organize", "order", "grab", "buy", "follow up", "do it", "do that",
            "have it done", "have that done", "have it ready", "have that ready", "have it sent", "have that sent",
        ]
        for action in actions {
            let text = "I'll " + action + " tomorrow"
            XCTAssertEqual(CommitmentFixture.compute([CommitmentFixture.event("promise", text)]).count, 1, text)
        }
        for text in ["Let me check", "let me find out", "Let me ask", "Leave it with me", "On it", "I can send it tomorrow"] {
            XCTAssertEqual(CommitmentFixture.compute([CommitmentFixture.event("promise", text)]).count, 1, text)
        }
    }

    func testNonPromisesAreExcluded() {
        let cases = [
            "I won't send it", "I will not send it", "I can't send it tomorrow", "I cannot send it tomorrow",
            "I couldn't send it", "I don’t think I’ll send it", "I might send it", "Maybe I'll send it",
            "I'll probably send it", "I'll try to send it", "I'll send it hopefully", "I'll send it if I finish",
            "Hopefully I'll send it", "I'll be late", "I'll be there", "I'll be home", "Let me know",
            "I sent it", "I was going to send it", "I'll send it?", "I can send it", "I can send it soon",
            "I'll sender tomorrow", "They said I'll send it tomorrow", "\"I'll send it tomorrow\"",
            "“I'll send it tomorrow.”", "'I'll send it tomorrow'", "‘I'll send it tomorrow’",
            "Quoted: \"Hello.\nI'll send it tomorrow.\"", "I'll try sending it tomorrow",
            "'Example speech.\nI'll send it tomorrow.'", "‘Example speech.\nI’ll send it tomorrow.’",
            "\"Example speech.\nI'll send it tomorrow", "“Example speech.\nI'll send it tomorrow",
        ]
        for text in cases {
            XCTAssertTrue(CommitmentFixture.compute([CommitmentFixture.event("promise", text)]).isEmpty, text)
        }
    }

    func testDirectionAndSourceMustQualify() {
        for source in [Event.Source.imessage, .sms, .email] {
            let promise = CommitmentFixture.event("promise", "I'll send it tomorrow", source: source)
            XCTAssertEqual(CommitmentFixture.compute([promise]).count, 1)
            for direction in [Event.Direction.incoming, .unknown] {
                var other = promise
                other.direction = direction
                XCTAssertTrue(CommitmentFixture.compute([other]).isEmpty)
            }
        }
        let notification = CommitmentFixture.event("notification", "I'll send it tomorrow", source: .notification)
        XCTAssertTrue(CommitmentFixture.compute([notification]).isEmpty)
    }

    func testEmailHistoryStopsAtEveryMarker() {
        for marker in [
            "> Earlier message",
            "On Tuesday Example Alex wrote:",
            "From: alex@example.com",
            "-----Original Message-----",
            "Sent from my example phone",
        ] {
            let text = "I'll bring the report tomorrow.\n  " + marker + "\nI'll send it Friday."
            let result = CommitmentFixture.compute([CommitmentFixture.event("mail", text, source: .email)])
            XCTAssertEqual(result.map(\.text), ["I'll bring the report tomorrow."], marker)
        }
    }

    func testSentenceBoundariesQuestionsAndOriginalWording() {
        let text = "Hello. I'll send it tomorrow! I'll call Friday?\nLet me check.\nOn it"
        let result = CommitmentFixture.compute([CommitmentFixture.event("promise", text)])
        XCTAssertEqual(Set(result.map(\.text)), ["I'll send it tomorrow!", "Let me check.", "On it"])
        let quotedObject = "I'll send the \"example report\" tomorrow."
        XCTAssertEqual(CommitmentFixture.compute([CommitmentFixture.event("object", quotedObject)]).first?.text, quotedObject)
        let unicodeLines = "I'll send it tomorrow\u{2028}On it\u{2029}Let me check"
        XCTAssertEqual(CommitmentFixture.compute([CommitmentFixture.event("lines", unicodeLines)]).count, 3)
    }

    func testExcerptUsesCharactersAndCutsTo160OnOneLine() throws {
        let exact = "I'll send " + String(repeating: "e\u{301}", count: 150)
        XCTAssertEqual(exact.count, 160)
        XCTAssertEqual(CommitmentFixture.compute([CommitmentFixture.event("exact", exact)]).first?.text, exact)
        let long = exact + "😀"
        let result = try XCTUnwrap(CommitmentFixture.compute([CommitmentFixture.event("long", long)]).first)
        XCTAssertEqual(result.text.count, 160)
        XCTAssertEqual(result.text, String(long.prefix(159)) + "…")
        let control = "I'll send\t\u{0000}it tomorrow"
        XCTAssertEqual(CommitmentFixture.compute([CommitmentFixture.event("control", control)]).first?.text, "I'll send it tomorrow")
    }
}

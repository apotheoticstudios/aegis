@testable import AegisKit
import XCTest

final class WakePhraseTests: XCTestCase {
    func testNamesGreetingsCaseAndPunctuation() {
        for name in ["aegis", "aegis's", "jarvas", "aegiss", "javis", "jervis", "aegis’s"] {
            for greeting in ["", "hey", "hi", "ok", "okay", "yo", "hello"] {
                let transcript = " \n\(greeting.uppercased()), \(name.uppercased())!!! "
                XCTAssertEqual(WakePhrase.match(transcript), .init(question: nil), transcript)
            }
        }
    }

    func testLeadingFillersAndFourthWordBoundary() {
        for text in ["um Aegis", "so, hey Aegis", "um so okay Aegis", "um so um Aegis"] {
            XCTAssertEqual(WakePhrase.match(text), .init(question: nil), text)
        }
        for text in ["um so um hey Aegis", "um so um so Aegis"] {
            XCTAssertNil(WakePhrase.match(text), text)
        }
    }

    func testOneBreathQuestionPreservesOriginalTextAndInternalPunctuation() {
        XCTAssertEqual(WakePhrase.match("Hey Aegis, what's up?"), .init(question: "what's up"))
        XCTAssertEqual(WakePhrase.match("Um, HELLO JERVIS: What's Next?!"), .init(question: "What's Next"))
        XCTAssertEqual(WakePhrase.match("Aegis—what’s next?"), .init(question: "what’s next"))
        XCTAssertEqual(WakePhrase.match("Aegis, what's next, then?"), .init(question: "what's next, then"))
        XCTAssertEqual(WakePhrase.match("Aegis,  \n how are you? \n"), .init(question: "how are you"))
        XCTAssertEqual(WakePhrase.match("Aegis, météo demain?"), .init(question: "météo demain"))
    }

    func testShortRemaindersOpenAndListen() {
        for text in ["Aegis", "Hey Aegis?", "Aegis, hello!", "Aegis, what's?", "Aegis… !!!"] {
            XCTAssertEqual(WakePhrase.match(text), .init(question: nil), text)
        }
    }

    func testMentionsSimilarWordsAndUnrecognizedPrefixesNeverWake() {
        for text in [
            "I told Aegis to help", "the Aegis app", "tell Aegis", "I said hey Aegis",
            "so the Aegis app", "um I told Aegis", "Travis", "hey Travis, what's up?",
            "service", "nervous", "Aegisian", "hey aegisx", "hello service",
            "", " \n ", "hey", "um so", "hey hi Aegis",
        ] {
            XCTAssertNil(WakePhrase.match(text), text)
        }
    }
}

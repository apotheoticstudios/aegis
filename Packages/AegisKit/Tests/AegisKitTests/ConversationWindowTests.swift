@testable import AegisKit
import XCTest

final class ConversationWindowTests: XCTestCase {
    func testWakeCaptureThinkingSpeakingAndFollowUp() {
        var window = ConversationWindow()
        XCTAssertEqual(window.state, .waitingForWake)
        XCTAssertEqual(window.wake(), .openPanel)
        XCTAssertEqual(window.state, .capturing)
        XCTAssertEqual(window.questionComplete("  what's next? \n"), .ask("what's next?"))
        XCTAssertEqual(window.state, .thinking)
        XCTAssertEqual(window.startedSpeaking(), .none)
        XCTAssertEqual(window.state, .speaking)
        XCTAssertEqual(window.finishedSpeaking(at: 10), .startCapture)
        XCTAssertEqual(window.state, .followUp(until: 16))
        XCTAssertEqual(window.heard(at: 15.99), .startCapture)
        XCTAssertEqual(window.state, .capturing)
        XCTAssertEqual(window.tick(now: 17), .none)
        XCTAssertEqual(window.questionComplete("why?"), .ask("why?"))
        XCTAssertEqual(window.startedSpeaking(), .none)
        XCTAssertEqual(window.finishedSpeaking(at: 20), .startCapture)
        XCTAssertEqual(window.state, .followUp(until: 26))
    }

    func testOneBreathWakeQuestion() throws {
        let match = try XCTUnwrap(WakePhrase.match("Hey Aegis, what's up?"))
        var window = ConversationWindow()
        XCTAssertEqual(window.wake(), .openPanel)
        XCTAssertEqual(try window.questionComplete(XCTUnwrap(match.question)), .ask("what's up"))
        XCTAssertEqual(window.state, .thinking)
    }

    func testFollowUpExpiresAtSixSecondsEvenWithoutSpeech() {
        var window = followUpWindow()
        XCTAssertEqual(window.tick(now: 15.99), .none)
        XCTAssertEqual(window.state, .followUp(until: 16))
        XCTAssertEqual(window.tick(now: 16), .stopListening)
        XCTAssertEqual(window.state, .waitingForWake)
        XCTAssertEqual(window.tick(now: 17), .none)
        XCTAssertEqual(window.heard(at: 17), .none)
        XCTAssertEqual(window.wake(), .openPanel)
    }

    func testSpeechAtOrAfterDeadlineRequiresAnotherWake() {
        for time in [16.0, 17.0] {
            var window = followUpWindow()
            XCTAssertEqual(window.heard(at: time), .stopListening)
            XCTAssertEqual(window.state, .waitingForWake)
            XCTAssertEqual(window.questionComplete("what next"), .none)
        }
    }

    func testSpeechAndWakeDuringPlaybackAreIgnored() {
        var window = ConversationWindow()
        XCTAssertEqual(window.wake(), .openPanel)
        XCTAssertEqual(window.questionComplete("what next"), .ask("what next"))
        XCTAssertEqual(window.heard(at: 1), .none)
        XCTAssertEqual(window.startedSpeaking(), .none)
        XCTAssertEqual(window.heard(at: 2), .none)
        XCTAssertEqual(window.wake(), .none)
        XCTAssertEqual(window.questionComplete("Aegis's own voice"), .none)
        XCTAssertEqual(window.tick(now: 100), .none)
        XCTAssertEqual(window.state, .speaking)
    }

    func testInvalidTransitionsBlankQuestionsAndInvalidTimesAreIgnored() {
        var window = ConversationWindow()
        XCTAssertEqual(window.questionComplete("hello there"), .none)
        XCTAssertEqual(window.startedSpeaking(), .none)
        XCTAssertEqual(window.finishedSpeaking(at: 0), .none)
        XCTAssertEqual(window.heard(at: 0), .none)
        XCTAssertEqual(window.wake(), .openPanel)
        XCTAssertEqual(window.wake(), .none)
        XCTAssertEqual(window.questionComplete(" \n "), .none)
        XCTAssertEqual(window.state, .capturing)
        XCTAssertEqual(window.questionComplete("hello there"), .ask("hello there"))
        XCTAssertEqual(window.questionComplete("duplicate"), .none)
        XCTAssertEqual(window.startedSpeaking(), .none)
        XCTAssertEqual(window.finishedSpeaking(at: .nan), .none)
        XCTAssertEqual(window.state, .speaking)
        XCTAssertEqual(window.finishedSpeaking(at: 10), .startCapture)
        XCTAssertEqual(window.heard(at: .nan), .none)
        XCTAssertEqual(window.tick(now: .infinity), .none)
        XCTAssertEqual(window.state, .followUp(until: 16))
    }

    func testCancelFromEveryActivePhaseAndIndependentCopies() {
        var capturing = ConversationWindow()
        XCTAssertEqual(capturing.wake(), .openPanel)
        var thinking = capturing
        XCTAssertEqual(thinking.questionComplete("what next"), .ask("what next"))
        var speaking = thinking
        XCTAssertEqual(speaking.startedSpeaking(), .none)
        for var window in [capturing, thinking, speaking, followUpWindow()] {
            XCTAssertEqual(window.cancel(), .stopListening)
            XCTAssertEqual(window.state, .waitingForWake)
            XCTAssertEqual(window.cancel(), .none)
            XCTAssertEqual(window.wake(), .openPanel)
        }
        XCTAssertEqual(capturing.state, .capturing)
        XCTAssertEqual(thinking.state, .thinking)
        XCTAssertEqual(speaking.state, .speaking)
    }

    private func followUpWindow() -> ConversationWindow {
        var window = ConversationWindow()
        XCTAssertEqual(window.wake(), .openPanel)
        XCTAssertEqual(window.questionComplete("what next"), .ask("what next"))
        XCTAssertEqual(window.startedSpeaking(), .none)
        XCTAssertEqual(window.finishedSpeaking(at: 10), .startCapture)
        return window
    }
}

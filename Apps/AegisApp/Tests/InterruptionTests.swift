@testable import Aegis
import AVFoundation
import XCTest

@MainActor
final class InterruptionTests: XCTestCase {
    func testQuestionsCorrectionsAndStopTakeTheTurnWithoutAWakeName() {
        for text in [
            "Wait", "Stop", "Please stop", "Sorry, could you repeat that?", "Is that tomorrow?", "Hold on",
            "Actually, tell me about tomorrow",
            "No, I meant tomorrow",
            "That's wrong", "Tell me the time", "Could you repeat that?", "What about tomorrow?",
            "What's next?", "Why did that happen?", "How much is that?", "What happened today?",
            "Translate that message", "Yeah, but can you explain that?", "End Conversation",
        ] {
            XCTAssertTrue(InterruptionIntent.accepts(text, playback: "Your synthetic brief is ready."), text)
        }
        for text in [
            "", "mm-hm", "Yeah", "Yes", "Okay", "Right", "No", "The kettle is boiling",
            "I spoke to someone yesterday", "What a lovely day", "The television is loud", "Actually",
            "Can you", "Could you please", "What about", "Is that", "No I", "No that", "That is not",
            "Actually the kettle is boiling", "Stop at the shops", "Wait for the bus", "Hold on to the rail",
            "Can we leave for lunch", "Should we buy tickets", "Let me finish my sandwich",
        ] {
            XCTAssertFalse(InterruptionIntent.accepts(text, playback: "Your synthetic brief is ready."), text)
        }
    }

    func testResidualPlaybackWordsCannotTakeTheTurn() {
        let playback = "What about tomorrow? Actually, tell me about tomorrow. Wait, the synthetic plan is ready."
        for text in ["What about", "What about tomorrow", "Actually, tell me about tomorrow", "Wait"] {
            XCTAssertFalse(InterruptionIntent.accepts(text, playback: playback), text)
        }
        XCTAssertTrue(InterruptionIntent.accepts("Hey Aegis", playback: playback, addressed: true))
        XCTAssertFalse(InterruptionIntent.accepts("Hey Aegis", playback: "You can say Hey Aegis.", addressed: true))
        XCTAssertTrue(InterruptionIntent.accepts("What about next week instead?", playback: playback))
        XCTAssertFalse(InterruptionIntent.accepts("Remember the synthetic code 1235", playback: "Remember the synthetic code 1234"))
    }

    func testEchoAfterTheFirstSixtyFourWordsStillCannotInterrupt() {
        let playback = String(repeating: "Invented introductory words. ", count: 40)
            + "What about tomorrow? You can say Hey Aegis."
        XCTAssertFalse(InterruptionIntent.accepts("What about tomorrow?", playback: playback))
        XCTAssertFalse(InterruptionIntent.accepts("Hey Aegis", playback: playback, addressed: true))
        var gate = InterruptionIntent.Confirmation()
        XCTAssertFalse(gate.accepts("What about tomorrow?", playback: playback, at: 1))
        XCTAssertFalse(gate.accepts("What about tomorrow?", playback: playback, at: 2))
        let scattered = ["how", "much", "does", "the", "parcel", "cost"].map {
            $0 + String(repeating: " invented filler", count: 12)
        }.joined(separator: " ")
        XCTAssertTrue(InterruptionIntent.accepts("How much does the parcel cost?", playback: scattered))
    }

    func testConfirmationRequiresConsistentRecognitionAcrossTime() {
        var gate = InterruptionIntent.Confirmation()
        let playback = "Your synthetic brief is ready."
        XCTAssertFalse(gate.accepts("What about tomorrow?", playback: playback, at: 1))
        XCTAssertFalse(gate.accepts("What about tomorrow instead?", playback: playback, at: 1.1))
        XCTAssertTrue(gate.accepts("What about tomorrow instead?", playback: playback, at: 1.41))
        gate.reset()
        XCTAssertFalse(gate.accepts("Stop", playback: playback, at: 5), "One isolated recognition must never stop playback.")
        XCTAssertFalse(gate.accepts("Stop", playback: playback, at: 5.2))
        XCTAssertTrue(gate.accepts("Stop", playback: playback, at: 5.41))
        XCTAssertFalse(gate.accepts("Stop", playback: playback, at: 6), "Accepted evidence cannot be reused for another interruption.")
        XCTAssertFalse(gate.accepts("Stop", playback: playback, at: 8), "A delayed isolated result cannot revive an old candidate.")
        XCTAssertTrue(gate.accepts("Stop", playback: playback, at: 8.41))
    }

    func testRevisionsRejectedWordsAndInvalidTimesResetConfirmation() {
        var gate = InterruptionIntent.Confirmation()
        let playback = "Your synthetic brief is ready."
        XCTAssertFalse(gate.accepts("What about tomorrow?", playback: playback, at: 1))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: 2))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: 2.3))
        XCTAssertFalse(gate.accepts("The kettle is boiling", playback: playback, at: 3))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: 4))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: .infinity))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: 5))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: 4.5))
        XCTAssertFalse(gate.accepts("Where is the folder?", playback: playback, at: 6))
        XCTAssertTrue(gate.accepts("Where is the folder?", playback: playback, at: 6.41))
    }

    func testExplicitAddressIsImmediateButStillRejectsEcho() {
        var gate = InterruptionIntent.Confirmation()
        XCTAssertTrue(gate.accepts("Hey Aegis", playback: "An invented answer.", addressed: true, at: 1))
        XCTAssertFalse(gate.accepts("Hey Aegis", playback: "You can say Hey Aegis.", addressed: true, at: 2))
        XCTAssertFalse(gate.accepts("What about tomorrow?", playback: "What about tomorrow?", at: 3))
        XCTAssertFalse(gate.accepts("What about tomorrow?", playback: "What about tomorrow?", at: 4))
    }

    func testConfirmedIntentKeepsTheOpeningOfTheSameUtterance() {
        let wake = WakeListener()
        var speaking = false
        var stopped = 0
        var asked: [String] = []
        wake.echoCancellationReady = true // Fake capability: no audio device or microphone is opened.
        wake.isSpeaking = { speaking }
        wake.isPlayingReply = { speaking }
        wake.playbackText = { "Your synthetic brief is ready." }
        wake.interruptSpeech = { speaking = false; stopped += 1 }
        wake.ask = { asked.append($0) }
        wake.wakeDetected()
        wake.segment("Give me a synthetic brief")
        speaking = true
        wake.tick(at: 1)
        XCTAssertEqual(wake.inputMode, .interruption)
        let id = wake.segmentID
        wake.receivedTranscript("Actually, what about", final: false, id: id, at: 1)
        wake.receivedTranscript("Actually, what about tomorrow", final: false, id: id, at: 1.1)
        XCTAssertTrue(speaking)
        XCTAssertEqual(stopped, 0)
        wake.receivedTranscript("Actually, what about tomorrow instead", final: false, id: id, at: 1.51)
        XCTAssertFalse(speaking)
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(wake.inputMode, .question)
        XCTAssertEqual(asked, ["Give me a synthetic brief"], "A partial result takes the turn, not a second model request.")
        wake.receivedTranscript("Actually, what about tomorrow instead?", final: true, id: id, at: 1.6)
        XCTAssertEqual(asked, ["Give me a synthetic brief", "Actually, what about tomorrow instead?"])
        XCTAssertEqual(stopped, 1)
    }

    func testUnacceptedSpeechDoesNotBecomeAQuestionWhenPlaybackEnds() {
        let wake = WakeListener()
        var speaking = true
        wake.echoCancellationReady = true
        wake.isSpeaking = { speaking }
        wake.isPlayingReply = { speaking }
        wake.interruptSpeech = { XCTFail("Background statements must not stop the reply.") }
        wake.ask = { _ in XCTFail("Unaccepted speech must never become a question.") }
        wake.tick(at: 1)
        let id = wake.segmentID
        wake.receivedTranscript("What about tomorrow?", final: false, id: id, at: 1)
        speaking = false
        wake.tick(at: 2)
        wake.receivedTranscript("What about tomorrow?", final: true, id: id, at: 2)
        XCTAssertNotEqual(id, wake.segmentID, "Discard recognition that began as an unaccepted interruption.")
    }

    func testExplicitWakeAddressInterruptsWithoutConfirmationDelay() {
        let wake = WakeListener()
        var speaking = true
        var stopped = 0
        wake.echoCancellationReady = true
        wake.isSpeaking = { speaking }
        wake.isPlayingReply = { speaking }
        wake.playbackText = { "Your synthetic brief is ready." }
        wake.interruptSpeech = { speaking = false; stopped += 1 }
        wake.tick(at: 1)
        wake.receivedTranscript("Hey Aegis", final: false, id: wake.segmentID, at: 1)
        XCTAssertFalse(speaking)
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(wake.inputMode, .question)
    }

    func testAnIsolatedFinalCannotStopAndNextUtteranceNeedsFreshConfirmation() {
        let wake = WakeListener()
        var speaking = true
        var asked: [String] = []
        wake.echoCancellationReady = true
        wake.isSpeaking = { speaking }
        wake.isPlayingReply = { speaking }
        wake.interruptSpeech = { speaking = false }
        wake.ask = { asked.append($0) }
        wake.tick(at: 1)
        let old = wake.segmentID
        wake.receivedTranscript("What about tomorrow?", final: true, id: old, at: 1)
        XCTAssertTrue(speaking)
        XCTAssertTrue(asked.isEmpty)
        let next = wake.segmentID
        XCTAssertNotEqual(old, next)
        wake.receivedTranscript("What about tomorrow?", final: false, id: next, at: 2)
        XCTAssertTrue(speaking)
        wake.receivedTranscript("What about tomorrow instead?", final: true, id: next, at: 2.41)
        XCTAssertFalse(speaking)
        XCTAssertEqual(asked, ["What about tomorrow instead?"])
        wake.receivedTranscript("What about tomorrow instead?", final: true, id: next, at: 3)
        XCTAssertEqual(asked.count, 1)
    }

    func testClosingPanelDiscardsPendingConfirmation() {
        let wake = WakeListener()
        var open = true
        wake.echoCancellationReady = true
        wake.isPanelOpen = { open }
        wake.isSpeaking = { true }
        wake.isPlayingReply = { true }
        wake.interruptSpeech = { XCTFail("A closed panel must discard the pending cue.") }
        wake.tick(at: 1)
        let id = wake.segmentID
        wake.receivedTranscript("Wait", final: false, id: id, at: 1)
        open = false
        wake.receivedTranscript("Wait", final: false, id: id, at: 1.41)
        XCTAssertNotEqual(id, wake.segmentID)
        open = true
        wake.tick(at: 2)
        wake.receivedTranscript("Wait", final: false, id: wake.segmentID, at: 2)
    }

    func testThinkingDiscardsPendingSpeechBeforeAReplacementReply() {
        let wake = WakeListener()
        var answering = false
        wake.echoCancellationReady = true
        wake.isSpeaking = { true }
        wake.isPlayingReply = { true }
        wake.isAnswering = { answering }
        wake.interruptSpeech = { XCTFail("Old recognition must not stop a replacement reply.") }
        wake.tick(at: 1)
        let old = wake.segmentID
        wake.receivedTranscript("Wait", final: false, id: old, at: 1)
        answering = true
        wake.tick(at: 1.1)
        XCTAssertNotEqual(old, wake.segmentID)
        XCTAssertEqual(wake.inputMode, .paused)
        answering = false
        wake.tick(at: 1.2)
        wake.receivedTranscript("Wait", final: true, id: old, at: 1.5)
        wake.receivedTranscript("Wait", final: false, id: wake.segmentID, at: 2)
        XCTAssertEqual(wake.inputMode, .interruption)
    }

    func testClosedPanelAndFailedEchoCancellationDisableInterruption() {
        let wake = WakeListener()
        var open = true
        wake.isSpeaking = { true }
        wake.isPlayingReply = { true }
        wake.isPanelOpen = { open }
        wake.interruptSpeech = { XCTFail("No raw speaker echo or closed-panel interruption.") }
        wake.tick(at: 1)
        XCTAssertEqual(wake.inputMode, .paused)
        wake.echoCancellationReady = true
        wake.tick(at: 2)
        XCTAssertEqual(wake.inputMode, .interruption)
        let id = wake.segmentID
        open = false
        wake.receivedTranscript("Wait, what about tomorrow?", final: true, id: id)
        wake.tick(at: 3)
        XCTAssertNotEqual(wake.inputMode, .interruption)
    }

    func testAcknowledgementAndManualMicrophoneNeverEnableInterruptionRecognition() {
        let wake = WakeListener()
        wake.echoCancellationReady = true
        wake.isSpeaking = { true } // The manual mic also uses this guard in the production app.
        wake.isPlayingReply = { false }
        wake.tick(at: 1)
        XCTAssertEqual(wake.inputMode, .paused)
        // A new listener acknowledges its wake before recording general speech.
        let acknowledging = WakeListener()
        var speaking = false
        acknowledging.echoCancellationReady = true
        acknowledging.isSpeaking = { speaking }
        acknowledging.isPlayingReply = { speaking }
        acknowledging.acknowledge = { speaking = true }
        acknowledging.wakeDetected()
        acknowledging.tick(at: 3)
        XCTAssertEqual(acknowledging.inputMode, .paused)
    }

    func testEndedConversationRejectsLateAcceptedPartial() {
        let wake = WakeListener()
        var speaking = false
        wake.echoCancellationReady = true
        wake.isPlayingReply = { speaking }
        wake.isSpeaking = { speaking }
        wake.interruptSpeech = { speaking = false }
        wake.ask = { _ in }
        wake.wakeDetected()
        wake.segment("Give me a synthetic brief")
        speaking = true
        wake.tick(at: 1)
        let id = wake.segmentID
        wake.receivedTranscript("Wait, what about tomorrow?", final: false, id: id, at: 1)
        wake.receivedTranscript("Wait, what about tomorrow?", final: false, id: id, at: 1.41)
        wake.segment("End Conversation")
        wake.ask = { _ in XCTFail("A cancelled recognizer cannot send another question.") }
        wake.receivedTranscript("Wait, what about tomorrow?", final: true, id: id)
        XCTAssertEqual(wake.inputMode, .wake)
    }

    func testAudioHandoverKeepsTheRecognitionStreamButPauseDiscardsIt() throws {
        let router = WakeAudioRouter()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0.2, count: 128)
        let count = InterruptionAudioCount()
        router.set(.interruption)
        router.audio.begin { _ in count.receive() }
        router.audio.onEnd = { count.end() }
        _ = router.receive(buffer)
        router.set(.question)
        _ = router.receive(buffer)
        XCTAssertEqual(count.frames, 2)
        XCTAssertEqual(count.ends, 0, "Promoting an interruption must not cut the recognizer's input.")
        router.set(.paused)
        _ = router.receive(buffer)
        XCTAssertEqual(count.frames, 2)
        XCTAssertEqual(count.ends, 1)
    }
}

private final class InterruptionAudioCount: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private var ended = 0
    var frames: Int {
        lock.withLock { received }
    }

    var ends: Int {
        lock.withLock { ended }
    }

    func receive() {
        lock.withLock { received += 1 }
    }

    func end() {
        lock.withLock { ended += 1 }
    }
}

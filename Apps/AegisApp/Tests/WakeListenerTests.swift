@testable import Aegis
import AegisKit
import AVFoundation
import XCTest

@MainActor
final class WakeListenerTests: XCTestCase {
    func testBareWakeAcknowledgesThenWaitsForQuestionWithoutTimingOutDuringSpeech() {
        let wake = WakeListener()
        var events: [String] = []
        var speaking = false
        wake.openPanel = { events.append("opened") }
        wake.acknowledge = { events.append("acknowledged"); speaking = true }
        wake.isSpeaking = { speaking }
        wake.ask = { events.append($0) }

        wake.wakeDetected()
        XCTAssertEqual(events, ["opened", "acknowledged"])
        wake.tick(at: 100)
        wake.segment("Yes?")
        XCTAssertEqual(events, ["opened", "acknowledged"], "Aegis's own voice must not become a question.")
        speaking = false
        wake.tick(at: 101)
        wake.tick(at: 108)
        wake.segment("What is next?")
        XCTAssertEqual(events, ["opened", "acknowledged", "What is next?"])
    }

    func testOnlyKeywordDetectionOpensTranscriptionAndExplicitCommandClosesIt() {
        let wake = WakeListener()
        var speaking = false
        var acknowledgements = 0
        wake.acknowledge = { acknowledgements += 1; speaking = true }
        wake.isSpeaking = { speaking }
        wake.tick(at: 0)
        XCTAssertEqual(wake.inputMode, .wake)
        wake.segment("Hey Aegis, what is next?")
        XCTAssertEqual(acknowledgements, 0, "An idle transcript is not an authorized wake event.")
        XCTAssertEqual(wake.inputMode, .wake)
        wake.wakeDetected()
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(wake.inputMode, .paused, "Do not transcribe the acknowledgement.")
        speaking = false
        wake.tick(at: 1)
        XCTAssertEqual(wake.inputMode, .question)
        wake.ask = { _ in speaking = true }
        wake.segment("What is next?")
        XCTAssertEqual(wake.inputMode, .paused)
        wake.tick(at: 2)
        speaking = false
        wake.tick(at: 3)
        XCTAssertEqual(wake.inputMode, .question)
        wake.tick(at: 3600)
        XCTAssertEqual(wake.inputMode, .question)
        wake.segment("End conversation.")
        XCTAssertEqual(wake.inputMode, .wake)
        wake.wakeDetected()
        XCTAssertEqual(acknowledgements, 2)
    }

    func testRepeatedWakeAcknowledgesDuringQuestionCaptureAndFollowUp() {
        let wake = WakeListener()
        var acknowledgements = 0
        var speaking = false
        var asked: [String] = []
        wake.acknowledge = { acknowledgements += 1; speaking = true }
        wake.isSpeaking = { speaking }
        wake.ask = { asked.append($0) }

        wake.wakeDetected()
        speaking = false
        wake.tick(at: 1)
        wake.segment("Hey Aegis")
        XCTAssertEqual(acknowledgements, 2)
        XCTAssertTrue(asked.isEmpty)
        speaking = false
        wake.tick(at: 2)
        wake.segment("What is next?")
        speaking = true
        wake.tick(at: 3)
        speaking = false
        wake.tick(at: 4)
        wake.segment("Hey Aegis")
        XCTAssertEqual(acknowledgements, 3)
        XCTAssertEqual(asked, ["What is next?"])
        speaking = false
        wake.tick(at: 5)
        wake.segment("Hey Aegis, what is the time?")
        XCTAssertEqual(asked, ["What is next?", "what is the time"])
    }

    func testSilenceKeepsConversationUntilExplicitEndAndRejectsLateRecognition() async {
        let model = PanelModel(service: SampleCoreService(), actions: nil)
        await model.ask("A synthetic question")
        XCTAssertFalse(model.thread.isEmpty)
        let wake = WakeListener()
        var speaking = false
        var ended = 0
        wake.isSpeaking = { speaking }
        wake.conversationEnded = { ended += 1; model.endVoiceConversation() }
        wake.wakeDetected()
        wake.segment("A synthetic question")
        speaking = true
        wake.tick(at: 1)
        speaking = false
        wake.tick(at: 2)
        let oldID = wake.segmentID
        wake.tick(at: 7.9)
        XCTAssertEqual(ended, 0)
        XCTAssertFalse(model.thread.isEmpty)
        wake.tick(at: 3600)
        XCTAssertEqual(ended, 0)
        XCTAssertFalse(model.thread.isEmpty)
        XCTAssertEqual(wake.inputMode, .question)
        wake.ask = { _ in XCTFail("The ending command must not be sent to the model.") }
        wake.segment("END CONVERSATION!")
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(model.thread.isEmpty, "CHAT keeps the transcript after the conversation ends")
        XCTAssertEqual(model.askState, .idle)
        wake.tick(at: 3601)
        XCTAssertEqual(ended, 1)

        var acknowledgements = 0
        wake.acknowledge = { acknowledgements += 1 }
        wake.segment("Hey Aegis", id: oldID)
        XCTAssertEqual(acknowledgements, 0, "Cancelled recognition cannot reopen a conversation.")
        wake.wakeDetected()
        XCTAssertEqual(acknowledgements, 1)
        wake.ask = { _ in XCTFail("A stale transcript must not become the new question.") }
        wake.segment("An old synthetic question", id: oldID)
    }

    func testSilenceAfterAcknowledgementKeepsListeningWithoutAQuestion() {
        let wake = WakeListener()
        var speaking = false
        var ended = 0
        wake.acknowledge = { speaking = true }
        wake.isSpeaking = { speaking }
        wake.conversationEnded = { ended += 1 }
        wake.wakeDetected()
        wake.tick(at: 100)
        XCTAssertEqual(ended, 0)
        speaking = false
        wake.tick(at: 101)
        wake.segment(nil)
        wake.tick(at: 3600)
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(wake.inputMode, .question)
        wake.ask = { _ in XCTFail("End Conversation must be handled locally.") }
        wake.segment("Hey Aegis, end conversation")
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(wake.inputMode, .wake)
        wake.segment("Unaddressed background speech")
        XCTAssertEqual(ended, 1)
    }

    func testMentioningEndConversationDoesNotEndItAndPlaybackCannotEndIt() {
        let wake = WakeListener()
        var speaking = false
        var ended = 0
        var questions: [String] = []
        wake.isSpeaking = { speaking }
        wake.conversationEnded = { ended += 1 }
        wake.ask = { questions.append($0) }
        wake.segment("End Conversation")
        XCTAssertEqual(ended, 0, "Idle transcripts cannot operate the conversation.")
        wake.wakeDetected()
        wake.segment("What does end conversation mean?")
        XCTAssertEqual(questions, ["What does end conversation mean?"])
        speaking = true
        wake.tick(at: 1)
        wake.segment("End Conversation")
        XCTAssertEqual(ended, 0, "Aegis's own playback cannot end the conversation.")
        speaking = false
        wake.tick(at: 2)
        wake.tick(at: 3600)
        wake.segment("Please explain the end conversation command")
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(ended, 0)
    }

    func testActiveAnswerDoesNotReopenCaptureBeforeItsModelDeadline() {
        let wake = WakeListener()
        var answering = true
        var speaking = false
        wake.isAnswering = { answering }
        wake.isSpeaking = { speaking }
        wake.wakeDetected()
        wake.segment("A synthetic question")
        wake.tick(at: 3600)
        XCTAssertEqual(wake.inputMode, .paused, "Do not capture a new question while the old job is still answering.")
        answering = false
        speaking = true
        wake.answerFinished()
        XCTAssertEqual(wake.inputMode, .paused, "The microphone must stay paused for playback.")
        speaking = false
        wake.tick(at: 3601)
        XCTAssertEqual(wake.inputMode, .question)
        wake.segment("End Conversation")
        wake.answerFinished()
        XCTAssertEqual(wake.inputMode, .wake, "A late completion cannot reopen an ended conversation.")
    }

    func testTypedQuestionPausesAnOpenMicrophoneUntilItsAnswerIsReady() {
        let wake = WakeListener()
        var answering = false
        wake.isAnswering = { answering }
        wake.wakeDetected()
        XCTAssertEqual(wake.inputMode, .question)
        answering = true
        wake.tick(at: 1)
        XCTAssertEqual(wake.inputMode, .paused)
        wake.ask = { _ in XCTFail("A stale transcript must not supersede the typed question.") }
        wake.segment("Old partial speech")
        answering = false
        wake.answerFinished()
        XCTAssertEqual(wake.inputMode, .question)
    }

    func testUnaddressedSpeechDoesNotOpenOrAcknowledge() {
        let wake = WakeListener()
        wake.openPanel = { XCTFail("Only the wake phrase may open the panel.") }
        wake.acknowledge = { XCTFail("Do not acknowledge background conversation.") }
        wake.ask = { _ in XCTFail("Do not submit background conversation.") }
        wake.segment("A synthetic conversation about Aegis.")
        wake.segment(nil)
    }

    func testIdleAudioIsNeverBufferedForQuestionRecognition() throws {
        let heard = BufferCount()
        let router = WakeAudioRouter(wakeAudio: { _ in heard.increment() })
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0.2, count: 480)
        router.set(.wake)
        for _ in 0 ..< 100 {
            _ = router.receive(buffer)
        }
        XCTAssertEqual(heard.value, 100)
        router.set(.question)
        let transcribed = BufferCount()
        router.audio.begin { _ in transcribed.increment() }
        XCTAssertEqual(transcribed.value, 0, "No pre-wake audio may be replayed into transcription.")
        _ = router.receive(buffer)
        XCTAssertEqual(transcribed.value, 1)
        router.set(.paused)
        _ = router.receive(buffer)
        XCTAssertEqual(transcribed.value, 1)
        router.set(.wake)
        _ = router.receive(buffer)
        XCTAssertEqual(heard.value, 101)
        XCTAssertEqual(transcribed.value, 1)
    }

    func testOwnSpeechIsRemovedFromAudioLeadIn() throws {
        let relay = AudioRelay()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0.25, count: 480)
        relay.receive(buffer)
        relay.discardRecent()
        let received = BufferCount()
        relay.begin { _ in received.increment() }
        XCTAssertEqual(received.value, 0, "The acknowledgement must not be replayed into recognition.")
        relay.receive(buffer)
        XCTAssertEqual(received.value, 1, "New microphone audio must still reach recognition.")
        relay.end()
    }
}

private final class BufferCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

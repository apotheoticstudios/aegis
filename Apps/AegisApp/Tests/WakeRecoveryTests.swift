@testable import Aegis
import AVFoundation
import XCTest

@MainActor
final class WakeRecoveryTests: XCTestCase {
    func testEmptyNativeResultReplaysTheWholeQuestionOnceAndRejectsLateResults() async throws {
        let router = WakeAudioRouter()
        let wake = WakeListener(router: router)
        let native = FakeSpeechSession(legacy: false)
        let legacy = FakeSpeechSession(legacy: true)
        let nativeReady = expectation(description: "native starts")
        let legacyReady = expectation(description: "fallback starts")
        native.started = { nativeReady.fulfill() }
        legacy.started = { legacyReady.fulfill() }
        var attempts: [Bool] = []
        var asked: [String] = []
        wake.makeSpeechSession = { fallback in attempts.append(fallback); return fallback ? legacy : native }
        wake.ask = { asked.append($0) }
        wake.wakeDetected()
        wake.beginSegment()
        await fulfillment(of: [nativeReady], timeout: 2)
        await Task.yield()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0.25, count: 160)
        _ = router.receive(buffer)
        native.deliver("", final: true)
        await fulfillment(of: [legacyReady], timeout: 2)
        await Task.yield()
        XCTAssertEqual(legacy.audio.frames, 160, "The fallback receives the original utterance, not the next question.")
        legacy.deliver("Where is the blue folder?", final: true)
        native.deliver("A stale invented result", final: true)
        XCTAssertEqual(attempts, [false, true])
        XCTAssertEqual(asked, ["Where is the blue folder?"])
    }

    func testBothRecognizersHearingNothingStaysQuietAndKeepsCaptureAvailable() async {
        let wake = WakeListener()
        let native = FakeSpeechSession(legacy: false)
        let legacy = FakeSpeechSession(legacy: true)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        native.started = { first.fulfill() }
        legacy.started = { second.fulfill() }
        var failures = 0
        wake.makeSpeechSession = { $0 ? legacy : native }
        wake.captureFailed = { failures += 1 }
        wake.ask = { _ in XCTFail("An empty transcript is not a question.") }
        wake.wakeDetected()
        wake.beginSegment()
        await fulfillment(of: [first], timeout: 2)
        native.deliver("", final: true)
        await fulfillment(of: [second], timeout: 2)
        legacy.deliver("", final: true)
        XCTAssertEqual(failures, 0, "noise with no words is dropped quietly")
        XCTAssertNil(wake.problem)
        XCTAssertEqual(wake.inputMode, .question, "still listening for the question")
    }

    func testEndingConversationCancelsAPreparingRecognizerAndItsLateCallback() async {
        let wake = WakeListener()
        let native = FakeSpeechSession(legacy: false)
        native.delay = true
        let started = expectation(description: "preparing")
        native.started = { started.fulfill() }
        wake.makeSpeechSession = { _ in native }
        wake.ask = { _ in XCTFail("Cancelled recognition cannot answer later.") }
        wake.wakeDetected()
        wake.beginSegment()
        await fulfillment(of: [started], timeout: 2)
        wake.segment("End Conversation")
        native.deliver("Where is the blue folder?", final: true)
        XCTAssertEqual(wake.inputMode, .wake)
    }

    func testSlowSetupRetainsOpeningAudioAndReplayIsBounded() throws {
        let relay = AudioRelay()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        relay.beginCapture()
        for _ in 0 ..< 200 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            buffer.floatChannelData?[0].initialize(repeating: 0.25, count: 160)
            relay.receive(buffer)
        }
        let first = RecoveryAudio()
        relay.begin { first.receive($0) }
        XCTAssertEqual(first.frames, 32000, "A slow model must not truncate a question to its final 1.5 seconds.")
        relay.end()
        let retry = RecoveryAudio()
        relay.begin { retry.receive($0) }
        XCTAssertEqual(retry.frames, first.frames)
        relay.discardRecent()
        relay.end()
        relay.beginCapture()
        for _ in 0 ..< 1500 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            relay.receive(buffer)
        }
        let bounded = RecoveryAudio()
        relay.begin { bounded.receive($0) }
        XCTAssertLessThanOrEqual(bounded.frames, 24 * 8000)
    }

    func testSlowNativeStartupSwitchesRecognizerAndTimeoutRejectsLateResults() async {
        let wake = WakeListener()
        let native = FakeSpeechSession(legacy: false)
        native.delay = true
        let legacy = FakeSpeechSession(legacy: true)
        let first = expectation(description: "native preparing")
        let second = expectation(description: "fallback started")
        native.started = { first.fulfill() }
        legacy.started = { second.fulfill() }
        wake.makeSpeechSession = { $0 ? legacy : native }
        wake.ask = { _ in XCTFail("Timed-out speech cannot submit a late question.") }
        var failures = 0
        wake.captureFailed = { failures += 1 }
        wake.wakeDetected()
        wake.beginSegment()
        await fulfillment(of: [first], timeout: 2)
        wake.tick(at: 11)
        await fulfillment(of: [second], timeout: 2)
        wake.tick(at: 24)
        legacy.deliver("Where is the blue folder?", final: true)
        XCTAssertEqual(failures, 1)
        XCTAssertNotNil(wake.problem)
        XCTAssertEqual(wake.inputMode, .question)
    }

    func testStalledAcknowledgementReleasesQuestionCapture() {
        let wake = WakeListener()
        var speaking = false
        var stopped = 0
        wake.isSpeaking = { speaking }
        wake.acknowledge = { speaking = true }
        wake.interruptSpeech = { stopped += 1; speaking = false }
        wake.wakeDetected()
        XCTAssertEqual(wake.inputMode, .paused)
        wake.tick(at: 31)
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(wake.inputMode, .question)
    }
}

@MainActor
private final class FakeSpeechSession: SpeechSession {
    nonisolated let isLegacy: Bool
    nonisolated let audio = RecoveryAudio()
    var started: () -> Void = {}
    var delay = false
    private var heard: (@MainActor @Sendable (String, Bool) -> Void)?

    init(legacy: Bool) {
        isLegacy = legacy
    }

    func start(heard: @escaping @MainActor @Sendable (String, Bool) -> Void) async -> Bool {
        self.heard = heard
        started()
        if delay {
            try? await Task.sleep(for: .seconds(30))
        }
        return !Task.isCancelled
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        audio.receive(buffer)
    }

    func finish() async {}
    func cancel() async {}
    func deliver(_ text: String, final: Bool) {
        heard?(text, final)
    }
}

private final class RecoveryAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var frames: Int {
        lock.withLock { count }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { count += Int(buffer.frameLength) }
    }
}

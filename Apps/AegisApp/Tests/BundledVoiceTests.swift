@testable import Aegis
import AppKit
import Darwin
import Foundation
@testable import SharedIPC
import SwiftUI
import XCTest

@MainActor
final class BundledVoiceTests: XCTestCase {
    func testBundledServiceSynthesizesAndExitsOnPanelClose() async throws {
        guard let models = Bundle.main.resourceURL?.appendingPathComponent("VoiceModels"),
              FileManager.default.fileExists(atPath: models.appendingPathComponent("voices/bm_george.bin").path)
        else { throw XCTSkip("Run the voice packaging script on the test app to exercise public model assets.") }
        let voice = VoiceXPCClient()
        for _ in 0 ..< 2 {
            let ready = await voice.prepare()
            XCTAssertTrue(ready)
            let process = await voice.processIdentifier
            let audio = await voice.audio(for: "Good morning. Your synthetic test is ready.")
            await voice.stop()
            let data = try XCTUnwrap(audio)
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertGreaterThan(data.count, 24000)
            let pid = try XCTUnwrap(process)
            XCTAssertNotEqual(pid, getpid(), "The model and CoreML caches must live outside the panel process.")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(kill(pid, 0), -1, "Panel close must exit the service and reclaim its model and caches.")
        }
    }

    func testBundledVoicePlaysThroughFinishingChainWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_VOICE_PLAYBACK"] == "1" else {
            throw XCTSkip("Opt in to audible synthetic speech to verify the output-device playback path.")
        }
        let voice = VoiceXPCClient()
        let audio = await voice.audio(for: "Aegis voice test. Playback is ready.")
        await voice.stop()
        let data = try XCTUnwrap(audio)
        let finish = VoiceFinish(rate: Voice.speakingRate)
        defer { finish.stop() }
        let completed = expectation(description: "The synthetic speech finishes playing")
        let playback = Task {
            let played = await finish.play(data)
            XCTAssertTrue(played)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 20)
        playback.cancel()
    }

    func testReadStopAndReopenWithAnimatedIndicatorWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_VOICE_PLAYBACK"] == "1" else {
            throw XCTSkip("Opt in to audible synthetic speech to exercise Read and the animated indicator.")
        }
        let voice = Voice()
        let host = NSHostingView(rootView: PlaybackIndicator(voice: voice))
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { voice.silence(); window.orderOut(nil) }
        for _ in 0 ..< 2 {
            voice.prepare(enabled: true)
            voice.speak("Aegis voice test. Reading is ready.")
            XCTAssertTrue(voice.speaking)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while voice.speaking, ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                host.display()
                try await Task.sleep(for: .milliseconds(16))
            }
            XCTAssertFalse(voice.speaking, "Read must finish, not remain silently busy.")
            voice.speak("This synthetic sentence will be cancelled.")
            voice.stopSpeaking()
            XCTAssertFalse(voice.speaking)
            voice.silence()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testWakeAcknowledgementThenSpokenAnswerWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_VOICE_PLAYBACK"] == "1" else {
            throw XCTSkip("Opt in to audible synthetic speech to exercise the wake acknowledgement.")
        }
        let voice = Voice()
        let wake = WakeListener()
        wake.acknowledge = { voice.speak("Yes?") }
        wake.isSpeaking = { voice.speaking }
        var questions: [String] = []
        wake.ask = { question in
            questions.append(question)
            voice.speak("Your synthetic answer is ready.")
        }
        defer { voice.silence() }
        wake.wakeDetected()
        XCTAssertTrue(voice.speaking)
        try await waitForSpeech(voice, wake: wake)
        XCTAssertTrue(questions.isEmpty)
        wake.segment("What is next?")
        XCTAssertEqual(questions, ["What is next?"])
        XCTAssertTrue(voice.speaking)
        try await waitForSpeech(voice, wake: wake)
    }

    func testNaturalInterruptionStopsRealSyntheticPlaybackWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_VOICE_PLAYBACK"] == "1" else {
            throw XCTSkip("Opt in to synthetic playback; interruption input is invented text, never a microphone.")
        }
        let voice = Voice()
        let wake = WakeListener()
        wake.echoCancellationReady = true // The input device is not opened in this synthetic test.
        wake.isPlayingReply = { voice.speaking }
        wake.isSpeaking = { voice.speaking }
        wake.playbackText = { voice.spokenText }
        wake.interruptSpeech = { voice.stopSpeaking() }
        var questions: [String] = []
        wake.ask = { questions.append($0) }
        defer { voice.silence() }
        wake.wakeDetected()
        voice.speak("This is an invented long answer. The synthetic meeting is tomorrow morning. The rest can wait.")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !voice.playingAudio, voice.speaking, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(voice.playingAudio, "Exercise interruption during actual playback, after synthesis has finished.")
        wake.tick(at: 1)
        XCTAssertEqual(wake.inputMode, .interruption)
        let id = wake.segmentID
        wake.receivedTranscript("Actually, what about tomorrow?", final: false, id: id, at: 1)
        XCTAssertTrue(voice.playingAudio, "One speculative partial must leave the reply playing.")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(voice.playingAudio)
        wake.receivedTranscript("Actually, what about tomorrow instead?", final: false, id: id, at: 1.45)
        XCTAssertFalse(voice.speaking, "Confirmed intent must stop synchronously without waiting for final text or a model.")
        XCTAssertFalse(voice.playingAudio, "The output player must stop too, not just the speaking indicator.")
        XCTAssertTrue(voice.spokenText.isEmpty)
        wake.receivedTranscript("Actually, what about Friday instead?", final: true, id: id)
        XCTAssertEqual(questions, ["Actually, what about Friday instead?"])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(voice.speaking, "Cancelled synthesis must not restart the old reply.")
    }

    private func waitForSpeech(_ voice: Voice, wake: WakeListener) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while voice.speaking, ContinuousClock.now < deadline {
            wake.tick()
            try await Task.sleep(for: .milliseconds(25))
        }
        wake.tick()
        XCTAssertFalse(voice.speaking)
    }
}

private struct PlaybackIndicator: View {
    let voice: Voice
    var body: some View {
        ReactorView(mode: voice.speaking ? .speaking : .idle, size: 100)
    }
}

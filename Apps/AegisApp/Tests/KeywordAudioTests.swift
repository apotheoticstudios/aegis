@testable import Aegis
import AVFoundation
import Foundation
@testable import SharedIPC
import WakeRuntime
import XCTest

@MainActor
final class KeywordAudioTests: XCTestCase {
    func testRealKeywordWorkerOpensListeningWithoutIdleTranscription() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_WAKE_KEYWORD"] == "1" else {
            throw XCTSkip("Opt in to synthesized keyword audio; no microphone is used.")
        }
        let router = WakeAudioRouter()
        let wake = WakeListener(router: router)
        var acknowledgements = 0
        wake.acknowledge = { acknowledgements += 1 }
        wake.ask = { _ in XCTFail("Keyword audio must never become a question.") }
        let found = expectation(description: "The audio-only keyword worker opens the question window")
        let directory = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("WakeModels")
        let ready = await router.keyword.prepare(directory: directory) {
            wake.wakeDetected()
            found.fulfill()
        }
        XCTAssertTrue(ready)
        defer { router.set(.paused); router.keyword.stop() }
        let voice = VoiceXPCClient()
        let wav = await voice.audio(for: "Hey Aegis.")
        await voice.stop()
        let buffer = try XCTUnwrap(VoiceFinish.playbackBuffer(from: XCTUnwrap(wav)))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        router.set(.wake)
        for start in stride(from: 0, to: Int(buffer.frameLength) + 48000, by: 1024) {
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 1024))
            chunk.frameLength = 1024
            let output = try XCTUnwrap(chunk.floatChannelData)
            for channel in 0 ..< Int(buffer.format.channelCount) {
                for frame in 0 ..< 1024 {
                    output[channel][frame] = start + frame < buffer.frameLength ? channels[channel][start + frame] : 0
                }
            }
            _ = router.receive(chunk)
            try await Task.sleep(for: .milliseconds(21))
        }
        await fulfillment(of: [found], timeout: 5)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(wake.inputMode, .question)
    }

    func testRealKeywordDetectorWithSyntheticSpeechAndNoise() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_WAKE_KEYWORD"] == "1" else {
            throw XCTSkip("Opt in to offline keyword inference on synthesized speech; no microphone is used.")
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let detector = try XCTUnwrap(KeywordDetector(directory: resources.appendingPathComponent("WakeModels"), additionalName: "Friday"))
        let voice = VoiceXPCClient()
        let phrases = [
            ("The synthetic weather report is ready.", false),
            ("I spoke to Aegis yesterday.", false),
            ("Hey there. The jar is on the shelf.", false),
            ("Hey Travis.", false),
            ("I spoke to Atlas yesterday.", false),
            ("Hey Friday.", true),
            ("Hey Aegis.", true),
            ("Hey Aegis.", true),
        ]
        for (index, (phrase, expected)) in phrases.enumerated() {
            let wav = await voice.audio(for: phrase)
            let buffer = try XCTUnwrap(VoiceFinish.playbackBuffer(from: XCTUnwrap(wav)))
            detector.reset()
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let rate = Int(buffer.format.sampleRate)
            var samples = Array(repeating: Float.zero, count: rate)
            samples += Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            samples += Array(repeating: Float.zero, count: rate)
            // Deterministic room-like noise at about -45 dBFS, no real recordings.
            var seed: UInt64 = 17
            for index in samples.indices {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                samples[index] += (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.02
            }
            var matches = 0
            for start in stride(from: 0, to: samples.count, by: 1024) {
                let chunk = Array(samples[start ..< min(start + 1024, samples.count)])
                if detector.accept(chunk, sampleRate: rate) {
                    matches += 1
                }
            }
            XCTAssertEqual(matches, expected ? 1 : 0, "Synthetic phrase case \(index)")
        }
        await voice.stop()
    }
}

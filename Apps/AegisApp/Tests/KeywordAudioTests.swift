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
        let ready = await router.keyword.prepare(directory: directory, name: "Friday") {
            wake.wakeDetected()
            found.fulfill()
        }
        XCTAssertTrue(ready)
        defer { router.set(.paused); router.keyword.stop() }
        let voice = VoiceXPCClient()
        let wav = await voice.audio(for: "Hey Friday.")
        await voice.stop()
        let buffer = try XCTUnwrap(VoiceFinish.playbackBuffer(from: XCTUnwrap(wav)))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        router.set(.wake)
        let leadIn = Int(buffer.format.sampleRate * 1.25)
        let end = leadIn + Int(buffer.frameLength) + Int(buffer.format.sampleRate)
        for start in stride(from: 0, to: end, by: 1024) {
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 1024))
            chunk.frameLength = 1024
            let output = try XCTUnwrap(chunk.floatChannelData)
            for channel in 0 ..< Int(buffer.format.channelCount) {
                for frame in 0 ..< 1024 {
                    let source = start + frame - leadIn
                    output[channel][frame] = (0 ..< Int(buffer.frameLength)).contains(source) ? channels[channel][source] * 0.1 : 0
                }
            }
            _ = router.receive(chunk)
            try await Task.sleep(for: .milliseconds(21))
        }
        await fulfillment(of: [found], timeout: 5)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(wake.inputMode, .question)
    }

    func testProlongedSilenceSkipsInferenceAndKeepsTheQuietLeadIn() {
        let rate = 16000
        let silent = Array(repeating: Float(0), count: 160)
        var gate = WakeSilenceGate(sampleRate: rate)
        let fed = (0 ..< 6000).filter { _ in gate.feed(silent) != nil }.count
        XCTAssertEqual(fed, 75, "Only the first 750 ms of a quiet minute needs decoding.")
        let quietOnset = Array(repeating: Float(0.0004), count: 160)
        XCTAssertNil(gate.feed(quietOnset))
        let quietSpeech = Array(repeating: Float(0.0006), count: 160)
        let resumed = gate.feed(quietSpeech)?.leadIn
        XCTAssertEqual(resumed?.count, 4000)
        XCTAssertEqual(resumed?.suffix(160), quietOnset[...])
        for _ in 0 ..< 75 {
            XCTAssertNotNil(gate.feed(silent), "Trailing blanks must reach the keyword decoder.")
        }
        XCTAssertNil(gate.feed(silent))
    }

    func testGatedAndUngatedDecodersUseTheSameDefaultAndCustomClips() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_WAKE_KEYWORD"] == "1" else {
            throw XCTSkip("Opt in to offline keyword inference on synthesized speech.")
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let detector = try XCTUnwrap(KeywordDetector(directory: resources.appendingPathComponent("WakeModels"), additionalName: "Friday"))
        let voice = VoiceXPCClient()
        for phrase in ["Hey Aegis.", "Hey Friday."] {
            let wav = await voice.audio(for: phrase)
            let buffer = try XCTUnwrap(VoiceFinish.playbackBuffer(from: XCTUnwrap(wav)))
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let rate = Int(buffer.format.sampleRate)
            for gain: Float in [1, 0.1] {
                let padding = Array(repeating: Float.zero, count: rate * 5 / 4)
                let speech = (0 ..< Int(buffer.frameLength)).map { channel[$0] * gain }
                let samples = padding + speech + padding
                let direct = Self.matches(samples, rate: rate, gated: false, detector: detector)
                let gated = Self.matches(samples, rate: rate, gated: true, detector: detector)
                XCTAssertTrue(!direct || gated, "Silence gating lost a baseline match at gain \(gain).")
            }
        }
        await voice.stop()
    }

    private static func matches(_ samples: [Float], rate: Int, gated: Bool, detector: KeywordDetector) -> Bool {
        detector.reset()
        var gate = WakeSilenceGate(sampleRate: rate)
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let chunk = Array(samples[start ..< min(start + 1024, samples.count)])
            if gated {
                guard let frame = gate.feed(chunk) else { continue }
                if let leadIn = frame.leadIn {
                    detector.reset()
                    if detector.accept(leadIn, sampleRate: rate) {
                        return true
                    }
                }
            }
            if detector.accept(chunk, sampleRate: rate) {
                return true
            }
        }
        return false
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

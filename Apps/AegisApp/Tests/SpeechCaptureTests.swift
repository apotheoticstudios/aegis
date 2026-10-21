@testable import Aegis
import AVFoundation
@testable import SharedIPC
import XCTest

@MainActor
final class SpeechCaptureTests: XCTestCase {
    func testInventedAudioThroughTheRealWakeCapturePath() async throws {
        try await captureInventedAudio(quiet: false)
    }

    func testQuietInventedAudioThroughTheRealWakeCapturePath() async throws {
        try await captureInventedAudio(quiet: true)
    }

    private func captureInventedAudio(quiet: Bool) async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_TRANSCRIBER"] == "1" else {
            throw XCTSkip("Opt in to local synthetic speech inference; no microphone is opened.")
        }
        let router = WakeAudioRouter()
        let wake = WakeListener(router: router)
        wake.listening = true // Fake input device; feed only synthesized buffers below.
        wake.wakeDetected()
        let asked = expectation(description: "A post-wake question reaches the app")
        wake.ask = { text in
            XCTAssertTrue(text.lowercased().contains("blue folder"))
            asked.fulfill()
        }
        let voice = VoiceXPCClient()
        let wav = await voice.audio(for: "Where is the blue folder?")
        await voice.stop()
        let buffer = try XCTUnwrap(VoiceFinish.playbackBuffer(from: XCTUnwrap(wav)))
        let samples = try XCTUnwrap(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        let energy = (0 ..< frames).reduce(Float.zero) { $0 + samples[0][$1] * samples[0][$1] }
        let rms = (energy / Float(frames)).squareRoot()
        let scale: Float = quiet ? pow(10, -52 / 20) / rms : 1
        var seed: UInt64 = 17
        let rate = buffer.format.sampleRate
        let lead = Int(rate)
        let total = lead + Int(buffer.frameLength) + Int(rate)
        for start in stride(from: 0, to: total, by: 1024) {
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 1024))
            chunk.frameLength = 1024
            for channel in 0 ..< Int(buffer.format.channelCount) {
                let output = try XCTUnwrap(chunk.floatChannelData?[channel])
                for frame in 0 ..< 1024 {
                    let position = start + frame - lead
                    let speech = (0 ..< Int(buffer.frameLength)).contains(position) ? samples[channel][position] * scale : 0
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    let noise = quiet ? (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.00275 : 0
                    output[frame] = speech + noise
                }
            }
            if router.receive(chunk) {
                let channel = try XCTUnwrap(chunk.floatChannelData?[0])
                let energy = (0 ..< 1024).reduce(Float.zero) { $0 + channel[$1] * channel[$1] }
                wake.heard(level: max(-120, 10 * log10(energy / 1024)), at: 0)
            }
            wake.tick()
            try await Task.sleep(for: .seconds(1024 / rate))
        }
        await fulfillment(of: [asked], timeout: 15)
        router.set(.paused)
        wake.listening = false // This fake source never installed an AVAudioEngine input node.
    }

    func testRealOnDeviceTranscriptionOfInventedAudioWithoutAMicrophone() async throws {
        try await transcribeInventedAudio(oppositeChannels: false)
    }

    func testRealIndependentFallbackTranscribesInventedAudio() async throws {
        try await transcribeInventedAudio(oppositeChannels: false, legacy: true)
    }

    func testOppositePhaseChannelsKeepTheSpeechDetectedOnTheFirstChannel() async throws {
        try await transcribeInventedAudio(oppositeChannels: true)
    }

    func testSevenChannelMicrophoneLayoutTranscribesTheVoiceChannel() async throws {
        try await transcribeInventedAudio(oppositeChannels: false, channels: 7)
    }

    func testFallbackAcceptsSevenChannelMicrophoneLayout() async throws {
        try await transcribeInventedAudio(oppositeChannels: false, legacy: true, channels: 7)
    }

    private func transcribeInventedAudio(oppositeChannels: Bool, legacy: Bool = false, channels: AVAudioChannelCount = 1) async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_TEST_TRANSCRIBER"] == "1" else {
            throw XCTSkip("Opt in to local speech-model inference on invented audio; no microphone is opened.")
        }
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                let voice = VoiceXPCClient()
                let wav = await voice.audio(for: "Where is the blue folder?")
                await voice.stop()
                let original = try XCTUnwrap(VoiceFinish.playbackBuffer(from: XCTUnwrap(wav)))
                let buffer: AVAudioPCMBuffer
                if oppositeChannels || channels > 1 {
                    let count = oppositeChannels ? 2 : channels
                    let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count))
                    let format = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32, sampleRate: original.format.sampleRate,
                        interleaved: false, channelLayout: layout
                    )
                    buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: original.frameLength))
                    buffer.frameLength = original.frameLength
                    let samples = try XCTUnwrap(original.floatChannelData?[0])
                    let channels = try XCTUnwrap(buffer.floatChannelData)
                    for channel in 0 ..< Int(buffer.format.channelCount) {
                        channels[channel].initialize(repeating: 0, count: Int(buffer.frameLength))
                    }
                    for frame in 0 ..< Int(original.frameLength) {
                        channels[0][frame] = samples[frame]
                        if oppositeChannels {
                            channels[1][frame] = -samples[frame]
                        }
                    }
                } else {
                    buffer = original
                }
                let session: any SpeechSession = legacy ? LegacySpeechSession() : LiveTranscriber()
                let final = expectation(description: "Invented audio produces a final transcript")
                var transcript = ""
                var updates = 0
                let ready = await session.start { words, complete in
                    updates += 1
                    transcript = words
                    if complete {
                        final.fulfill()
                    }
                }
                XCTAssertTrue(ready)
                guard ready else { return }
                let samples = try XCTUnwrap(buffer.floatChannelData)
                for start in stride(from: 0, to: Int(buffer.frameLength), by: 1024) {
                    let size = min(1024, Int(buffer.frameLength) - start)
                    let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(size)))
                    chunk.frameLength = AVAudioFrameCount(size)
                    for channel in 0 ..< Int(buffer.format.channelCount) {
                        chunk.floatChannelData?[channel].update(from: samples[channel].advanced(by: start), count: size)
                    }
                    session.feed(chunk)
                    try await Task.sleep(for: .milliseconds(5))
                }
                await session.finish()
                await fulfillment(of: [final], timeout: 15)
                await session.cancel()
                XCTAssertGreaterThan(updates, 0)
                XCTAssertTrue(transcript.lowercased().contains("blue folder"), "The fixed invented phrase must survive finalization.")
                return
            }
        #endif
        throw XCTSkip("SpeechAnalyzer needs macOS 26.")
    }
}

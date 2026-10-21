@testable import Aegis
import AVFoundation
import XCTest

@MainActor
final class VoiceFinishTests: XCTestCase {
    func testModelMonoWaveConvertsToStereoWithoutLosingSignalOrDuration() throws {
        let buffer = try XCTUnwrap(VoiceFinish.playbackBuffer(from: wave()))
        XCTAssertEqual(buffer.format.sampleRate, 48000)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(Int(buffer.frameLength), 12000, accuracy: 32)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< 2 {
            XCTAssertTrue((0 ..< Int(buffer.frameLength)).contains { abs(channels[channel][$0]) > 0.1 })
        }
        XCTAssertNil(VoiceFinish.playbackBuffer(from: Data("invalid synthetic audio".utf8)))
    }

    func testMonoModelAudioRendersThroughRealEffectsWithoutAnOutputDevice() async throws {
        let engine = AVAudioEngine()
        let finish = VoiceFinish(rate: Voice.speakingRate, engine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        defer { finish.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var result: Bool?
        let playback = Task { result = await finish.play(wave()) }
        defer { playback.cancel() }
        var peak: Float = 0
        for _ in 0 ..< 100 where result == nil {
            if engine.isRunning {
                let status = try engine.renderOffline(1024, to: output)
                if status == .success, let channels = output.floatChannelData {
                    for frame in 0 ..< Int(output.frameLength) {
                        peak = max(peak, abs(channels[0][frame]))
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(peak, 0.01, "The effects must produce non-silent output from the model's mono WAV.")
        // Offline rendering has no hardware playback completion. Stop must still release the waiter.
        finish.stop()
        await playback.value
        XCTAssertEqual(result, false, "Stop must unblock playback even without an output device.")
    }

    private func wave() -> Data {
        // A quarter-second synthetic 440 Hz tone in the model's 24 kHz, mono, signed 16-bit format.
        var data = Data()
        func bytes(_ value: some Any) {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); bytes(UInt32(12036).littleEndian)
        data.append(contentsOf: "WAVEfmt ".utf8); bytes(UInt32(16).littleEndian)
        bytes(UInt16(1).littleEndian); bytes(UInt16(1).littleEndian)
        bytes(UInt32(24000).littleEndian); bytes(UInt32(48000).littleEndian)
        bytes(UInt16(2).littleEndian); bytes(UInt16(16).littleEndian)
        data.append(contentsOf: "data".utf8); bytes(UInt32(12000).littleEndian)
        for index in 0 ..< 6000 {
            bytes(Int16(sin(Double(index) * 2 * .pi * 440 / 24000) * 8000).littleEndian)
        }
        return data
    }
}

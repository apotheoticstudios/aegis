@testable import Aegis
import AVFoundation
import XCTest

final class SpeechAudioTests: XCTestCase {
    func testReferenceChannelsCannotDiluteOrCancelTheVoice() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 7))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        input.frameLength = 160
        let channels = try XCTUnwrap(input.floatChannelData)
        for channel in 0 ..< 7 {
            channels[channel].initialize(repeating: channel == 0 ? 0.01 : -0.01, count: 160)
        }
        let mono = try XCTUnwrap(SpeechAudio.voiceChannel(input))
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.format.sampleRate, 48000)
        XCTAssertEqual(mono.frameLength, 160)
        let voice = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0 ..< 160 {
            XCTAssertEqual(voice[frame], 0.01)
        }
    }

    func testInterleavedInputUsesTheCorrectStrideAndRetainedCopiesAreIndependent() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        input.frameLength = 160
        let data = try XCTUnwrap(input.floatChannelData?[0])
        for frame in 0 ..< 160 {
            data[frame * 2] = Float(frame) / 1000; data[frame * 2 + 1] = -1
        }
        let mono = try XCTUnwrap(SpeechAudio.voiceChannel(input, alwaysCopy: true))
        data.initialize(repeating: 0, count: 320)
        let voice = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0 ..< 160 {
            XCTAssertEqual(voice[frame], Float(frame) / 1000)
        }
    }
}

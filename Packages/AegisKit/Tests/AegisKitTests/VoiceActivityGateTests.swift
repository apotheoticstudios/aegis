@testable import AegisKit
import Foundation
import XCTest

final class VoiceActivityGateTests: XCTestCase {
    func testStartNeeds150MillisecondsAndEndNeeds700Milliseconds() {
        var gate = VoiceActivityGate()
        XCTAssertNil(gate.feed(level: -60, at: 0))
        XCTAssertNil(gate.feed(level: -30, at: 1))
        XCTAssertNil(gate.feed(level: -30, at: 1.14))
        XCTAssertEqual(gate.feed(level: -30, at: 1.15), .speechStarted(1))
        XCTAssertNil(gate.feed(level: -60, at: 2))
        XCTAssertNil(gate.feed(level: -60, at: 2.69))
        XCTAssertEqual(gate.feed(level: -60, at: 2.7), .speechEnded(started: 1, ended: 2.7))
        XCTAssertNil(gate.feed(level: -60, at: 2.72))
    }

    func testRegular20MillisecondFramesConfirmOnFirstFrameAfterDeadline() {
        var gate = VoiceActivityGate()
        for frame in 0 ..< 8 {
            XCTAssertNil(gate.feed(level: -30, at: Double(frame) * 0.02))
        }
        XCTAssertEqual(gate.feed(level: -30, at: 0.16), .speechStarted(0))
        for frame in 50 ..< 85 {
            XCTAssertNil(gate.feed(level: -60, at: Double(frame) * 0.02))
        }
        let end = Double(85) * 0.02
        XCTAssertEqual(gate.feed(level: -60, at: end), .speechEnded(started: 0, ended: end))
    }

    func testClicksAndInterruptedOnsetsNeverAccumulateIntoSpeech() {
        var gate = VoiceActivityGate()
        for frame in 0 ..< 100 {
            let level: Float = frame.isMultiple(of: 5) ? 0 : -60
            XCTAssertNil(gate.feed(level: level, at: Double(frame) * 0.02))
        }
        XCTAssertNil(gate.feed(level: -30, at: 3))
        XCTAssertNil(gate.feed(level: -60, at: 3.14))
        XCTAssertNil(gate.feed(level: -30, at: 3.16))
        XCTAssertNil(gate.feed(level: -30, at: 3.3))
        XCTAssertEqual(gate.feed(level: -30, at: 3.32), .speechStarted(3.16))
    }

    func testBriefPauseDoesNotEndSpeechAndResetsSilenceTimer() {
        var gate = VoiceActivityGate()
        XCTAssertNil(gate.feed(level: -30, at: 0))
        XCTAssertEqual(gate.feed(level: -30, at: 0.16), .speechStarted(0))
        XCTAssertNil(gate.feed(level: -60, at: 1))
        XCTAssertNil(gate.feed(level: -60, at: 1.6))
        XCTAssertNil(gate.feed(level: -30, at: 1.62))
        XCTAssertNil(gate.feed(level: -60, at: 2))
        XCTAssertNil(gate.feed(level: -60, at: 2.69))
        XCTAssertEqual(gate.feed(level: -60, at: 2.7), .speechEnded(started: 0, ended: 2.7))
    }

    func testNoiseFloorFollowsGradualRiseWithoutFalseSpeech() {
        var gate = VoiceActivityGate()
        for frame in 0 ... 2000 {
            let level = Float(-60) + Float(frame) * 0.01
            XCTAssertNil(gate.feed(level: level, at: Double(frame) * 0.02))
        }
        for frame in 2001 ... 2050 {
            XCTAssertNil(gate.feed(level: -38, at: Double(frame) * 0.02))
        }
        XCTAssertNil(gate.feed(level: -20, at: 42))
        XCTAssertEqual(gate.feed(level: -20, at: 42.16), .speechStarted(42))
    }

    func testVeryQuietRoomRetainsMinus50ThresholdMinimum() {
        var gate = VoiceActivityGate()
        for frame in 0 ... 1000 {
            XCTAssertNil(gate.feed(level: -90, at: Double(frame) * 0.02))
        }
        XCTAssertNil(gate.feed(level: -55, at: 21))
        XCTAssertNil(gate.feed(level: -55, at: 21.2))
        XCTAssertNil(gate.feed(level: -45, at: 22))
        XCTAssertEqual(gate.feed(level: -45, at: 22.16), .speechStarted(22))
    }

    func testContinuousSpeechIsCappedAt12SecondsAndGateRearms() {
        var gate = VoiceActivityGate()
        XCTAssertNil(gate.feed(level: -30, at: 0))
        XCTAssertEqual(gate.feed(level: -30, at: 0.16), .speechStarted(0))
        XCTAssertNil(gate.feed(level: -30, at: 11.98))
        XCTAssertEqual(gate.feed(level: -30, at: 12), .speechEnded(started: 0, ended: 12))
        XCTAssertNil(gate.feed(level: -30, at: 12.02))
        XCTAssertEqual(gate.feed(level: -30, at: 12.18), .speechStarted(12.02))
    }

    func testLateFrameReportsCapDeadlineAndInvalidFramesAreIgnored() {
        var gate = VoiceActivityGate()
        XCTAssertNil(gate.feed(level: .nan, at: 0))
        XCTAssertNil(gate.feed(level: -30, at: .infinity))
        XCTAssertNil(gate.feed(level: -30, at: 1))
        XCTAssertNil(gate.feed(level: -60, at: 0.5))
        XCTAssertNil(gate.feed(level: -60, at: 1))
        XCTAssertEqual(gate.feed(level: -30, at: 1.16), .speechStarted(1))
        XCTAssertEqual(gate.feed(level: -30, at: 14), .speechEnded(started: 1, ended: 13))
    }

    func testCopiesHaveIndependentState() {
        var original = VoiceActivityGate()
        XCTAssertNil(original.feed(level: -30, at: 0))
        var copy = original
        XCTAssertEqual(original.feed(level: -30, at: 0.16), .speechStarted(0))
        XCTAssertNil(copy.feed(level: -60, at: 0.16))
        XCTAssertNil(copy.feed(level: -30, at: 0.18))
    }
}

@testable import Aegis
import AegisKit
import XCTest

final class WakeActivityGateTests: XCTestCase {
    func testQuietQuestionIsAcceptedButCannotInterruptPlayback() {
        var question = WakeActivityGate()
        var interruption = WakeActivityGate()
        for frame in 0 ..< 100 {
            _ = question.feed(level: -60, at: Double(frame) * 0.02, capture: false)
            _ = interruption.feed(level: -60, at: Double(frame) * 0.02, capture: false)
        }
        var events: [VoiceActivityGate.Event] = []
        for frame in 100 ..< 250 {
            let level: Float = frame < 200 ? -52 : -60
            if let event = question.feed(level: level, at: Double(frame) * 0.02, capture: true) {
                events.append(event)
            }
            XCTAssertNil(interruption.feed(level: level, at: Double(frame) * 0.02, capture: true, interruption: true))
        }
        XCTAssertEqual(events.count, 2, "A normal question only eight dB above the room must start and finish.")
    }

    func testSofterSyllablesStayInOneQuestionAndClicksAreIgnored() {
        var gate = WakeActivityGate()
        for frame in 0 ..< 100 {
            _ = gate.feed(level: -60, at: Double(frame) * 0.02, capture: false)
        }
        for frame in 100 ..< 150 {
            XCTAssertNil(gate.feed(level: frame == 110 ? -25 : -60, at: Double(frame) * 0.02, capture: true))
        }
        var events: [VoiceActivityGate.Event] = []
        for frame in 150 ..< 350 {
            let level: Float = frame < 175 ? -50 : (frame < 300 ? -56 : -60)
            if let event = gate.feed(level: level, at: Double(frame) * 0.02, capture: true) {
                events.append(event)
            }
        }
        XCTAssertEqual(events.count, 2)
        guard case let .speechEnded(_, end) = events.last else { return XCTFail("A real pause ends the question.") }
        XCTAssertGreaterThan(end, 6, "Softer words must remain inside the same question.")
    }

    func testLoudRoomDoesNotBecomeEndlessSpeech() {
        var gate = WakeActivityGate()
        for frame in 0 ..< 1000 {
            let level: Float = frame.isMultiple(of: 5) ? -42 : -44
            XCTAssertNil(gate.feed(level: level, at: Double(frame) * 0.02, capture: true))
        }
    }

    func testWakeCalibrationSurvivesPlaybackAndQuestionEndsInRoomNoise() {
        var gate = WakeActivityGate()
        for frame in 0 ..< 100 {
            XCTAssertNil(gate.feed(level: -44, at: Double(frame) * 0.02, capture: false))
        }
        gate.resetSpeech()
        var events: [VoiceActivityGate.Event] = []
        for frame in 100 ..< 220 {
            let level: Float = frame < 150 ? -24 : -44
            if let event = gate.feed(level: level, at: Double(frame) * 0.02, capture: true) {
                events.append(event)
            }
        }
        XCTAssertEqual(events.count, 2)
        guard events.count == 2 else { return }
        guard case .speechStarted = events[0], case let .speechEnded(_, ended) = events[1] else {
            return XCTFail("A question must start and finish without the 12-second cutoff.")
        }
        XCTAssertLessThan(ended, 4)
        gate.resetSpeech()
        for frame in 220 ..< 400 {
            XCTAssertNil(gate.feed(level: -44, at: Double(frame) * 0.02, capture: true))
        }
    }
}

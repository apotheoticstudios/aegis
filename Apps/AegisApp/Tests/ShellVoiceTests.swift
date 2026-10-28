@testable import Aegis
import AegisKit
import XCTest

/// AegisShell's voice overlay follows the panel's own voice turn. Synthetic words only.
@MainActor
final class ShellVoiceTests: XCTestCase {
    func testTheOverlayFollowsTheVoiceTurn() {
        let answer = Answer(
            text: "Twenty-five minutes.", eventIDs: [], scheduleIDs: [], model: "synthetic", generatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(
            ShellVoice.turn(heard: "how long until", ask: .idle, partial: ""),
            .init(state: .listening, transcript: "how long until")
        )
        XCTAssertEqual(
            ShellVoice.turn(heard: nil, ask: .asking("how long?"), partial: ""),
            .init(state: .thinking, transcript: "how long?")
        )
        XCTAssertEqual(
            ShellVoice.turn(heard: nil, ask: .asking("how long?"), partial: "Twenty"),
            .init(state: .answering, transcript: "how long?", answer: "Twenty")
        )
        XCTAssertEqual(
            ShellVoice.turn(heard: nil, ask: .answered(question: "how long?", answer: answer), partial: ""),
            .init(state: .answering, transcript: "how long?", answer: "Twenty-five minutes.")
        )
        XCTAssertEqual(
            ShellVoice.turn(heard: nil, ask: .failed(question: "how long?", message: "Not now."), partial: ""),
            .init(state: .answering, transcript: "how long?", answer: "Not now.")
        )
        // Listening again shows the new words, not the answer before them.
        XCTAssertEqual(ShellVoice.turn(heard: "", ask: .answered(question: "how long?", answer: answer), partial: "").state, .listening)
    }
}

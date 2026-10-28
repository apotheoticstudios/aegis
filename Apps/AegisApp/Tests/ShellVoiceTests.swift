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

    func testItSaysWhatAegisReadInKindsAndCounts() {
        func answer(_ events: [String], _ schedule: [String]) -> Answer {
            Answer(text: "Done.", eventIDs: events, scheduleIDs: schedule, model: "synthetic", generatedAt: Date(timeIntervalSince1970: 1))
        }
        let sources = SampleCoreService.recentEvents(now: Date(timeIntervalSince1970: 1_000_000)).reduce(into: [String: Event]()) {
            $0[$1.id] = $1
        }
        let message = sources.values.first { $0.source == .imessage || $0.source == .sms }
        let mail = sources.values.first { $0.source == .email }
        XCTAssertNil(ShellVoice.read(answer([], []), sources: sources))
        XCTAssertEqual(ShellVoice.read(answer([], ["s1"]), sources: sources), "Read: 1 calendar event")
        XCTAssertEqual(
            ShellVoice.read(answer([message?.id, mail?.id, "not-loaded"].compactMap(\.self), ["s1", "s2"]), sources: sources),
            "Read: 2 calendar events · 1 message · 1 email · 1 item"
        )
    }
}

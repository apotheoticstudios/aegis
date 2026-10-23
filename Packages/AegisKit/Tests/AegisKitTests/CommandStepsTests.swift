@testable import AegisKit
import Foundation
import XCTest

/// General commands, slice 4 (#47): several requests in one line become a plan's parts.
final class CommandStepsTests: XCTestCase {
    private func parts(_ text: String) -> [String]? {
        CommandPlan.parts(text, now: Date(timeIntervalSince1970: 1000), calendar: Calendar(identifier: .gregorian))
    }

    func testSeveralRequestsSplit() {
        XCTAssertEqual(parts("open Safari, go to apple.com and play music"), ["open Safari", "go to apple.com", "play music"])
        XCTAssertEqual(parts("Hey Aegis, mute and then turn on dark mode please"), ["mute", "turn on dark mode"])
        XCTAssertEqual(parts("run the Work shortcut; open Slack"), ["run the Work shortcut", "open Slack"])
        XCTAssertEqual(
            parts("remind me to call Mum at 5, then open Spotify"),
            ["remind me to call Mum at 5", "open Spotify"]
        )
        XCTAssertEqual(
            parts("open Safari and make a note called salt and pepper"),
            ["open Safari", "make a note called salt and pepper"]
        )
    }

    func testOneRequestStaysOne() {
        for text in [
            "make a note called salt and pepper", "remind me to buy eggs, milk and bread", "play my rock and roll playlist",
            "directions to Brisbane and the Gold Coast", "open Safari", "text Sam I'll grab milk and bread",
        ] {
            XCTAssertNil(parts(text), text)
        }
    }

    func testEveryPartMustBeACommand() {
        XCTAssertNil(parts("what's the weather and open Safari"))
        XCTAssertNil(parts("open Safari and tell me a joke"))
        XCTAssertNil(parts((1 ... 7).map { _ in "mute" }.joined(separator: " and ")), "at most six steps")
        XCTAssertEqual(parts((1 ... 6).map { _ in "mute" }.joined(separator: " and "))?.count, 6)
    }

    func testFreeTextEndsOnlyAtThen() {
        XCTAssertNil(parts("text Sam I'm late and open the door"), "“and open the door” stays in the message")
        XCTAssertNil(parts("remind me to turn off the oven and start the dishwasher"))
        XCTAssertNil(parts("make a note called pack and run the sprinkler"))
        XCTAssertEqual(parts("make a note called Groceries; mute"), ["make a note called Groceries", "mute"])
        XCTAssertEqual(parts("text Sam I'm late, then open Spotify"), ["text Sam I'm late", "open Spotify"])
        XCTAssertEqual(parts("open Spotify and text Sam I'm late"), ["open Spotify", "text Sam I'm late"])
    }

    func testGoAnswersTheCard() {
        XCTAssertEqual(ActionReply.parse("Go"), true)
        XCTAssertEqual(ActionReply.parse("go on"), true)
        XCTAssertNil(ActionReply.parse("go to apple.com"))
    }
}

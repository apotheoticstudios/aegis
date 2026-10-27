import AegisKit
import XCTest

final class WindowLayoutTests: XCTestCase {
    func testEveryOwnerExample() throws {
        let examples: [(String, [WindowPlacement])] = [
            ("Mail left, calendar right", [place("Mail", .left), place("calendar", .right)]),
            ("put Mail on the left and Calendar on the right", [place("Mail", .left), place("Calendar", .right)]),
            ("Safari left Xcode right", [place("Safari", .left), place("Xcode", .right)]),
            ("Xcode on the left two thirds, Terminal on the right third", [place("Xcode", .leftTwoThirds), place("Terminal", .rightThird)]),
            (
                "Notes top right, Music bottom right, Safari left",
                [place("Notes", .topRight), place("Music", .bottomRight), place("Safari", .left)]
            ),
            ("focus on Xcode", [place("Xcode", .full)]),
            ("Xcode full screen", [place("Xcode", .full)]),
            ("maximise Safari", [place("Safari", .full)]),
            ("centre Notes", [place("Notes", .centre)]),
            ("Notes in the middle", [place("Notes", .centre)]),
            ("split Safari and Mail", [place("Safari", .left), place("Mail", .right)]),
        ]
        let area = WindowArea(x: 0, y: 37, width: 1470, height: 900)
        for (text, expected) in examples {
            let placements = try XCTUnwrap(WindowLayoutCommand.parse(text), text)
            XCTAssertEqual(placements, expected, text)
            for (index, first) in placements.enumerated() {
                for second in placements.dropFirst(index + 1) {
                    XCTAssertFalse(overlaps(first.zone.frame(in: area), second.zone.frame(in: area)), text)
                }
            }
        }
    }

    func testNormalisationPreservesAppSpelling() {
        for text in [
            "  Aegis, please put mAiL on the LEFT and Calendar on the RIGHT!  ",
            "Hey Aegis please put mAiL on the left and Calendar on the right?",
            "Jarvis: mAiL left, Calendar right, please.",
            "okay Aegis mAiL left Calendar right",
        ] {
            XCTAssertEqual(WindowLayoutCommand.parse(text), [place("mAiL", .left), place("Calendar", .right)], text)
        }
        XCTAssertEqual(
            WindowLayoutCommand.parse("  Visual Studio Code left, Café right. "),
            [place("Visual Studio Code", .left), place("Café", .right)]
        )
        XCTAssertEqual(WindowLayoutCommand.parse("split\tSafari AND Mail"), [place("Safari", .left), place("Mail", .right)])
        XCTAssertEqual(place("  Notes  ", .centre).app, "Notes")
    }

    func testAllZonesCanBeNamed() {
        let phrases: [(String, WindowZone)] = [
            ("left", .left), ("right", .right), ("top", .top), ("bottom", .bottom),
            ("top left", .topLeft), ("top right", .topRight), ("bottom left", .bottomLeft), ("bottom right", .bottomRight),
            ("left third", .leftThird), ("centre third", .centreThird), ("right third", .rightThird),
            ("left two thirds", .leftTwoThirds), ("right two thirds", .rightTwoThirds),
            ("centre", .centre), ("full screen", .full),
        ]
        XCTAssertEqual(Set(phrases.map(\.1)), Set(WindowZone.allCases))
        for (phrase, zone) in phrases {
            XCTAssertEqual(WindowLayoutCommand.parse("Notes \(phrase)"), [place("Notes", zone)], phrase)
        }
        XCTAssertEqual(WindowLayoutCommand.parse("maximize Safari"), [place("Safari", .full)])
        XCTAssertEqual(WindowLayoutCommand.parse("center Notes"), [place("Notes", .centre)])
    }

    func testRejectsNonLayoutsAndIncompleteRequests() {
        for text in [
            "", "  ", "left on read", "what's left today", "right now", "Mail", "left", "focus on", "centre", "split Safari",
            "split Safari and Mail and Notes", "Mail left,", "Mail left and", "Mail left and Calendar",
            "Mail left, Calendar right, tell me a joke", "Mail left tomorrow", "Mail sideways, Calendar right",
            "Mail left; Calendar right", "Mail left\nCalendar right", "Mail left, Calendar left",
            "Notes centre, Safari in the middle", "focus on Mail, Calendar right",
        ] {
            XCTAssertNil(WindowLayoutCommand.parse(text), text)
        }
    }

    func testPlacementAndNameLimits() {
        XCTAssertEqual(WindowLayoutCommand.parse("Notes top left, Music top right, Safari bottom left, Mail bottom right")?.count, 4)
        XCTAssertNil(WindowLayoutCommand.parse("Notes top left, Music top right, Safari bottom left, Mail bottom right, Xcode full screen"))
        let longestName = String(repeating: "é", count: 40)
        XCTAssertEqual(WindowLayoutCommand.parse("\(longestName) left"), [place(longestName, .left)])
        let tooLong = longestName + "é"
        for text in ["\(tooLong) left", "focus on \(tooLong)", "centre \(tooLong)", "split Safari and \(tooLong)"] {
            XCTAssertNil(WindowLayoutCommand.parse(text), text)
        }
    }

    func testExactFramesForEveryZone() {
        let area = WindowArea(x: 0, y: 37, width: 1470, height: 900)
        let frames: [(WindowZone, WindowArea)] = [
            (.left, WindowArea(x: 8, y: 45, width: 723, height: 884)),
            (.right, WindowArea(x: 739, y: 45, width: 723, height: 884)),
            (.top, WindowArea(x: 8, y: 45, width: 1454, height: 438)),
            (.bottom, WindowArea(x: 8, y: 491, width: 1454, height: 438)),
            (.topLeft, WindowArea(x: 8, y: 45, width: 723, height: 438)),
            (.topRight, WindowArea(x: 739, y: 45, width: 723, height: 438)),
            (.bottomLeft, WindowArea(x: 8, y: 491, width: 723, height: 438)),
            (.bottomRight, WindowArea(x: 739, y: 491, width: 723, height: 438)),
            (.leftThird, WindowArea(x: 8, y: 45, width: 1438.0 / 3, height: 884)),
            (.centreThird, WindowArea(x: 1486.0 / 3, y: 45, width: 1438.0 / 3, height: 884)),
            (.rightThird, WindowArea(x: 2948.0 / 3, y: 45, width: 1438.0 / 3, height: 884)),
            (.leftTwoThirds, WindowArea(x: 8, y: 45, width: 2900.0 / 3, height: 884)),
            (.rightTwoThirds, WindowArea(x: 1486.0 / 3, y: 45, width: 2900.0 / 3, height: 884)),
            (.centre, WindowArea(x: 294, y: 172, width: 882, height: 630)),
            (.full, WindowArea(x: 8, y: 45, width: 1454, height: 884)),
        ]
        XCTAssertEqual(Set(frames.map(\.0)), Set(WindowZone.allCases))
        for (zone, expected) in frames {
            let actual = zone.frame(in: area, gap: 8)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, zone.rawValue)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, zone.rawValue)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, zone.rawValue)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, zone.rawValue)
            XCTAssertEqual(zone.frame(in: area), actual)
        }
    }

    func testZeroGapAndTranslatedOrigin() {
        XCTAssertEqual(
            WindowZone.left.frame(in: WindowArea(x: -1470, y: -900, width: 1470, height: 900), gap: 0),
            WindowArea(x: -1470, y: -900, width: 735, height: 900)
        )
        let area = WindowArea(x: 10, y: 20, width: 100, height: 80)
        XCTAssertEqual(WindowZone.full.frame(in: area, gap: 4), WindowArea(x: 14, y: 24, width: 92, height: 72))
    }

    private func place(_ app: String, _ zone: WindowZone) -> WindowPlacement {
        WindowPlacement(app: app, zone: zone)
    }

    private func overlaps(_ first: WindowArea, _ second: WindowArea) -> Bool {
        max(first.x, second.x) < min(first.x + first.width, second.x + second.width)
            && max(first.y, second.y) < min(first.y + first.height, second.y + second.height)
    }
}

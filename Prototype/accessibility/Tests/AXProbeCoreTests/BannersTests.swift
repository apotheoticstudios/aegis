@testable import AXProbeCore
import XCTest

/// Synthetic accessibility trees only; nothing here touches the real UI.
final class BannersTests: XCTestCase {
    private func banner(
        texts: [Int],
        matched: [[String]] = [],
        buttons: Int = 1,
        subrole: String = "AXNotificationCenterBanner"
    ) -> NodeSnapshot {
        var children: [NodeSnapshot] = [NodeSnapshot(role: "AXImage")]
        for (index, length) in texts.enumerated() {
            let labels = index < matched.count ? matched[index] : []
            children.append(NodeSnapshot(role: "AXStaticText", textLength: length, matched: labels))
        }
        children += Array(repeating: NodeSnapshot(role: "AXButton", textLength: 5), count: buttons)
        return NodeSnapshot(role: "AXGroup", subrole: subrole, identifierLength: 6, children: children)
    }

    private var window: NodeSnapshot {
        NodeSnapshot(role: "AXWindow", children: [
            NodeSnapshot(role: "AXGroup", children: [banner(texts: [8, 14, 37])]),
            NodeSnapshot(role: "AXGroup", subrole: "AXSomethingElse", children: [NodeSnapshot(role: "AXStaticText", textLength: 3)]),
            banner(texts: [], subrole: "AXNotificationCenterAlert"),
        ])
    }

    func testFindsBannersAndAlertsBySubrole() {
        let found = Banners.find(in: window)
        XCTAssertEqual(found.map(\.subrole), ["AXNotificationCenterBanner", "AXNotificationCenterAlert"])
    }

    func testDoesNotSearchInsideABannerAgain() {
        let nested = banner(texts: [4])
        let outer = NodeSnapshot(role: "AXGroup", subrole: "AXNotificationCenterBanner", children: [nested])
        XCTAssertEqual(Banners.find(in: outer).count, 1)
    }

    func testSummaryCountsFieldsAndLengthsOnly() {
        let summary = Banners.summarize(banner(texts: [8, 14, 37], buttons: 2))
        XCTAssertEqual(summary.textLengths, [8, 14, 37])
        XCTAssertEqual(summary.buttons, 2)
        XCTAssertEqual(summary.images, 1)
        XCTAssertEqual(summary.found, [])
        XCTAssertTrue(summary.hasText)
    }

    func testBannerWithNoReadableTextIsReportedAsSuch() {
        let summary = Banners.summarize(banner(texts: [0, 0]))
        XCTAssertFalse(summary.hasText)
        XCTAssertEqual(summary.textLengths, [0, 0])
    }

    func testSummaryReportsWhichExpectedFieldsWereFound() {
        let summary = Banners.summarize(banner(texts: [12, 17, 16], matched: [["app"], ["title"], []]))
        XCTAssertEqual(summary.found, ["app", "title"])
        XCTAssertFalse(summary.found.contains("body"))
    }

    func testTextOnContainersCountsButButtonLabelsDoNot() {
        let group = NodeSnapshot(role: "AXGroup", subrole: "AXNotificationCenterBanner", textLength: 41, children: [
            NodeSnapshot(role: "AXButton", textLength: 5),
            NodeSnapshot(role: "AXImage", textLength: 8),
        ])
        let summary = Banners.summarize(group)
        XCTAssertEqual(summary.textLengths, [41, 8])
        XCTAssertEqual(summary.buttons, 1)
        XCTAssertEqual(summary.images, 1)
        XCTAssertTrue(summary.hasText)
    }

    func testMarkersMatchCaseInsensitivelyAndNeverOnEmptyMarkers() {
        let expected = ["app": "Script Editor", "title": "AEGIS TEST TITLE", "body": ""]
        XCTAssertEqual(Markers.labels(in: "aegis test title", expected: expected), ["title"])
        XCTAssertEqual(Markers.labels(in: "From Script Editor: AEGIS TEST TITLE", expected: expected), ["app", "title"])
        XCTAssertEqual(Markers.labels(in: "anything at all", expected: expected), [])
    }

    func testInspectChecksEveryTextAttributeForMarkers() {
        let expected = ["app": "Example Chat", "title": "AEGIS TEST TITLE", "body": "AEGIS TEST BODY"]
        // The value holds something unrelated; the markers sit in the title and description.
        let result = Markers.inspect(["12:41", "Example Chat", "AEGIS TEST TITLE, AEGIS TEST BODY"], expected: expected)
        XCTAssertEqual(result.length, 5)
        XCTAssertEqual(result.matched, ["app", "body", "title"])
        XCTAssertEqual(Markers.inspect([nil, "", nil], expected: expected).length, nil)
    }

    func testDescribeShowsStructureNotTextOrIdentifiers() {
        let lines = Banners.describe(window)
        XCTAssertEqual(lines.first, "AXWindow (3 children)")
        XCTAssertTrue(lines.contains("      AXStaticText text=37ch"))
        XCTAssertTrue(lines.contains { $0.contains("AXNotificationCenterBanner id=6ch") })
        let shape = #"^ *AX[A-Za-z]+(/AX[A-Za-z]+)?( id=\d+ch)?( text=\d+ch)?( matches=[a-z,]+)?( \(\d+ children\))?$"#
        for line in lines {
            XCTAssertNotNil(line.range(of: shape, options: .regularExpression), line)
        }
    }

    func testDescribeShowsMarkerMatchesOnly() {
        let lines = Banners.describe(banner(texts: [17], matched: [["title"]]))
        XCTAssertTrue(lines.contains("  AXStaticText text=17ch matches=title"))
    }

    func testDescribeStopsAtMaxDepth() {
        let lines = Banners.describe(window, maxDepth: 1)
        XCTAssertFalse(lines.contains { $0.hasPrefix("    ") })
    }
}

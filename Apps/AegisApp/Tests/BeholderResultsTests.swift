@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Result grouping only: invented findings, no search runs and no service is contacted.
final class BeholderResultsTests: XCTestCase {
    private let checked = Date(timeIntervalSince1970: 1_790_000_000)

    private func finding(_ provider: BeholderProvider, _ status: BeholderFinding.Status, checked: Bool = true) -> BeholderFinding {
        BeholderFinding(provider: provider, status: status, checkedAt: checked ? self.checked : nil)
    }

    func testEachOutcomeLandsInTheGroupThatSaysWhatToDoNext() {
        XCTAssertEqual(BeholderResultGroup.of(finding(.github, .candidate)), .found)
        XCTAssertEqual(BeholderResultGroup.of(finding(.gitlab, .noResult)), .noResult)
        XCTAssertEqual(BeholderResultGroup.of(finding(.hackerNews, .limited)), .unresolved)
        XCTAssertEqual(BeholderResultGroup.of(finding(.dev, .unavailable)), .unresolved)
        XCTAssertEqual(BeholderResultGroup.of(finding(.codeberg, .queued, checked: false)), .checking)
        XCTAssertEqual(BeholderResultGroup.of(finding(.keybase, .checking, checked: false)), .checking)
        XCTAssertEqual(BeholderResultGroup.of(finding(.lichess, .cancelled, checked: false)), .notChecked)
        XCTAssertEqual(BeholderResultGroup.of(finding(.scratch, .unsupported, checked: false)), .notChecked)
        var manual = finding(.instagram, .manual, checked: false)
        manual.access = .manual
        manual.preparedProfileURL = BeholderProvider.instagram.manualEntry?.profileURL("ExampleAlex")
        XCTAssertEqual(BeholderResultGroup.of(manual), .manual)
    }

    func testCandidateWithoutACheckTimeIsNeverShownAsFound() {
        // Matches BeholderEvidence: an unchecked record is not an observation.
        XCTAssertEqual(BeholderResultGroup.of(finding(.github, .candidate, checked: false)), .notChecked)
    }

    func testFoundComesFirstAndOnlyQuietGroupsFold() {
        XCTAssertEqual(BeholderResultGroup.allCases.first, .found)
        XCTAssertEqual(BeholderResultGroup.allCases.filter(\.folded), [.noResult, .notChecked])
        for group in BeholderResultGroup.allCases {
            XCTAssertFalse(group.title.isEmpty)
            XCTAssertFalse(group.hint.isEmpty)
        }
    }

    @MainActor func testEmptyDashboardAndEmbeddedTabsRender() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in native window capture: RENDER_BEHOLDER=1 on an unlocked Mac.")
        }
        let model = BeholderModel()
        _ = try model.people.create("Example Alex")
        let views: [(String, CGSize, AnyView)] = [
            ("empty-compact", CGSize(width: 900, height: 650), AnyView(BeholderDashboard(research: BeholderModel()))),
            ("empty-wide", CGSize(width: 1400, height: 900), AnyView(BeholderDashboard(research: BeholderModel()))),
            ("tab-people", CGSize(width: 868, height: 420), AnyView(BeholderPeopleView(research: model, embedded: true))),
            ("tab-evidence", CGSize(width: 868, height: 420), AnyView(BeholderCorrelationView(research: model, embedded: true))),
            ("tab-planner", CGSize(width: 868, height: 420), AnyView(BeholderQueryPlannerView(embedded: true))),
        ]
        for (name, size, view) in views {
            let host = NSHostingView(rootView: view
                .frame(width: size.width, height: size.height).background(HUD.void).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-\(name).png"))
        }
    }
}

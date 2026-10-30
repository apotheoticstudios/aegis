@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Pure selection rules only: no search runs and no service is contacted.
final class BeholderSourcesTests: XCTestCase {
    private let all = BeholderProvider.allCases

    func testOriginalFourAreTheFirstCases() {
        XCTAssertEqual(BeholderSources.original, Set(all.prefix(4)))
        XCTAssertEqual(BeholderSources.original, [.github, .gitlab, .hackerNews, .dev])
    }

    func testFilterMatchesTitleOrHostInAllCasesOrder() {
        XCTAssertEqual(BeholderSources.matching(""), all)
        XCTAssertEqual(BeholderSources.matching("   "), all)
        for term in ["git", "GITHUB", "api.github", "firebaseio", "news", "dev", ".com", "zz-no-such-source"] {
            let result = BeholderSources.matching(term)
            XCTAssertEqual(result, all.filter(result.contains), "Order must follow allCases for \(term)")
            for provider in all {
                let expected = provider.title.localizedStandardContains(term) || provider.host.localizedStandardContains(term)
                XCTAssertEqual(result.contains(provider), expected, "\(provider) for \(term)")
            }
        }
        XCTAssertTrue(BeholderSources.matching("git").contains(.github))
        XCTAssertTrue(BeholderSources.matching("Hacker").contains(.hackerNews))
        XCTAssertTrue(BeholderSources.matching("firebaseio").contains(.hackerNews))
        XCTAssertTrue(BeholderSources.matching("zz-no-such-source").isEmpty)
        XCTAssertEqual(BeholderSources.matching("", in: [.dev, .github]), [.dev, .github])
    }

    func testSummaryCountsAgainstEverySource() {
        XCTAssertEqual(BeholderSources.summary([]), "0 of \(all.count) sources")
        XCTAssertEqual(BeholderSources.summary(Set(all)), "\(all.count) of \(all.count) sources")
        XCTAssertEqual(BeholderSources.summary(BeholderSources.original), "4 of \(all.count) sources")
    }

    @MainActor func testSelectionNeverStartsASearch() {
        let model = BeholderModel()
        model.query = "ExampleAlex"
        model.selected = BeholderSources.original
        model.selected = []
        model.selected = Set(all)
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.findings.isEmpty)
    }

    @MainActor func testSyntheticSourceLayoutsRender() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in native window capture: RENDER_BEHOLDER=1 on an unlocked Mac.")
        }
        let model = BeholderModel()
        model.query = "ExampleAlex"
        let selection = Binding.constant(BeholderSources.original)
        try capture(BeholderSourceList(selected: selection).fixedSize(), size: CGSize(width: 320, height: 520), name: "sources-list")
        try capture(BeholderDashboard(research: model), size: CGSize(width: 900, height: 650), name: "sources-compact")
        try capture(BeholderDashboard(research: model), size: CGSize(width: 1400, height: 760), name: "sources-wide")
    }

    @MainActor private func capture(_ view: some View, size: CGSize, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(HUD.void).environment(\.colorScheme, .dark))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -3000, y: -3000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-\(name).png"))
    }
}

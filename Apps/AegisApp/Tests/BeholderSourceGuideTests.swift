@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Catalogue metadata only: no search runs and no service is contacted.
final class BeholderSourceGuideTests: XCTestCase {
    private typealias Guide = BeholderSourceGuide
    private let all = BeholderProvider.allCases

    func testEveryProviderIsFiledAndEveryCategoryIsUsed() {
        let grouped = Dictionary(grouping: all, by: Guide.category)
        XCTAssertEqual(grouped.values.map(\.count).reduce(0, +), all.count)
        for category in Guide.Category.allCases {
            XCTAssertFalse(grouped[category, default: []].isEmpty, "\(category) has no sources")
            XCTAssertFalse(category.terms.isEmpty)
            XCTAssertTrue(category.terms.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty })
        }
        let spotChecks: [(BeholderProvider, Guide.Category)] = [
            (.github, .developer), (.mastodonOnline, .social), (.mixcloud, .music), (.lichess, .gaming),
            (.writeAs, .publishing), (.framaTube, .video), (.patreon, .support), (.goodreads, .interests), (.flickr, .creative),
        ]
        for (provider, category) in spotChecks {
            XCTAssertEqual(Guide.category(provider), category, "\(provider)")
        }
    }

    func testFiltersCombineInCatalogueOrder() {
        XCTAssertEqual(Guide.filter(), all)
        XCTAssertEqual(Guide.filter(access: .manual), all.filter(\.isManual))
        XCTAssertEqual(Guide.filter(access: .automatic), all.filter { !$0.isManual })
        let cases: [(String, Guide.Category?)] = [
            ("", .social), ("chess", nil), ("code", nil), ("api.github", nil), ("GitHub", .developer), ("photo", .creative), (
                "  music ",
                nil
            ),
        ]
        for access in Guide.Access.allCases {
            for (text, category) in cases {
                let result = Guide.filter(text, category: category, access: access)
                XCTAssertEqual(result, all.filter(result.contains), "Catalogue order for \(text)")
                XCTAssertTrue(result.allSatisfy { access.includes($0) && (category == nil || Guide.category($0) == category) })
                XCTAssertEqual(result, Guide.filter(text, category: category, access: access), "Deterministic for \(text)")
            }
        }
        let social = Guide.filter("", category: .social, access: .automatic)
        XCTAssertTrue(social.contains(.bluesky) && social.contains(.mastodon) && social.contains(.socialVivaldi))
        XCTAssertFalse(social.contains(.instagram))
        let chess = Set(Guide.filter("chess"))
        XCTAssertTrue(chess.contains(.lichess) && chess.contains(.chess), "Topic words match, not only names")
        XCTAssertTrue(Guide.filter("code").contains(.gitlab))
        XCTAssertEqual(Guide.filter("api.github"), [.github])
        XCTAssertEqual(Guide.filter("  music ", access: .automatic), [.mixcloud])
    }

    func testEmptyResultsAreEmpty() {
        XCTAssertTrue(Guide.filter("zz-no-such-source").isEmpty)
        XCTAssertTrue(Guide.filter("mastodon", access: .manual).isEmpty)
        XCTAssertTrue(Guide.filter(category: .support, access: .automatic).isEmpty)
        XCTAssertTrue(Guide.filter("instagram", category: .developer).isEmpty)
    }

    @MainActor func testVisibleSelectionNeverBroadensOrStartsASearch() {
        let model = BeholderModel()
        model.query = "ExampleAlex"
        let before: Set<BeholderProvider> = [.github, .instagram]
        let visible = Guide.filter("", category: .music, access: .automatic)
        XCTAssertEqual(visible, [.mixcloud])
        model.selected = Guide.select(visible, in: before)
        XCTAssertEqual(model.selected, [.github, .instagram, .mixcloud])
        model.selected = Guide.deselect(Guide.filter("", category: .social), in: model.selected)
        XCTAssertEqual(model.selected, [.github, .mixcloud], "Only shown sources are removed")
        XCTAssertEqual(Guide.select([], in: before), before)
        XCTAssertEqual(Guide.deselect([], in: before), before)
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.findings.isEmpty)
        XCTAssertEqual(BeholderModel().selected, BeholderProvider.originalSources, "The guide adds no default sources")
    }

    @MainActor func testSyntheticGuideRendersAtCompactWidth() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in native window capture: RENDER_BEHOLDER=1 on an unlocked Mac.")
        }
        let view = BeholderSourceGuideView(selected: .constant(BeholderProvider.originalSources))
            .frame(width: 340, height: 720, alignment: .top).background(HUD.void).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 340, height: 720),
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
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-source-guide.png"))
    }
}

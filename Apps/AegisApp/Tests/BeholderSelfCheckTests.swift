@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// The self-check list is fixed links: nothing here is fetched, and no handle or email is sent.
final class BeholderSelfCheckTests: XCTestCase {
    private let places = BeholderSelfCheck.places

    func testEveryPlaceIsAFixedHTTPSPageWithPlainWords() throws {
        XCTAssertEqual(Set(places.map(\.id)).count, places.count)
        for place in places {
            for page in [place.page] + (place.source.map { [$0] } ?? []) {
                let url = try XCTUnwrap(page.url, place.id)
                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host(), page.host)
                XCTAssertNil(url.query)
                XCTAssertTrue(page.path.hasPrefix("/"), place.id)
            }
            XCTAssertFalse(place.name.isEmpty)
            XCTAssertFalse(place.what.isEmpty)
            XCTAssertFalse(place.action.isEmpty)
        }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: BeholderSelfCheck.checked + "T00:00:00Z"))
    }

    func testEachGroupHasAPlaceAndBreachesAreOnlyALink() {
        for kind in BeholderSelfCheck.Kind.allCases {
            XCTAssertFalse(places.filter { $0.kind == kind }.isEmpty, kind.rawValue)
        }
        XCTAssertEqual(places.filter { $0.kind == .breach }.map(\.page.host), ["haveibeenpwned.com"])
    }

    func testSelfCheckSourceHasNoNetworkingOrPersonalFields() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Beholder")
        for name in ["BeholderSelfCheck.swift", "BeholderSelfCheckView.swift"] {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for banned in ["URLSession", "URLRequest", "NSWorkspace"] {
                XCTAssertFalse(source.contains(banned), "\(name) contains \(banned)")
            }
        }
        // The list links to pages, never to anyone's email address.
        let list = try String(contentsOf: folder.appendingPathComponent("BeholderSelfCheck.swift"), encoding: .utf8)
        XCTAssertFalse(list.contains("@"))
    }

    @MainActor func testSelfCheckRenders() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in native window capture: RENDER_BEHOLDER=1 on an unlocked Mac.")
        }
        let size = CGSize(width: 868, height: 640)
        let host = NSHostingView(rootView: BeholderSelfCheckView(sources: BeholderProvider.allCases.count) { _ in }
            .frame(width: size.width, height: size.height).background(HUD.void).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-self-check.png"))
    }
}

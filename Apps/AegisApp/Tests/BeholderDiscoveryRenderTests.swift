@testable import Aegis
import AppKit
import SwiftUI
import XCTest

final class BeholderDiscoveryRenderTests: XCTestCase {
    @MainActor func testInventedNameEmailPhoneAndIPLayouts() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else { throw XCTSkip("Opt-in invented discovery layouts") }
        let model = BeholderModel(client: NoDiscoveryNetwork())
        let finding = BeholderFinding(
            provider: .github,
            status: .candidate,
            checkedAt: .init(timeIntervalSince1970: 1_800_000_000),
            sourceURL: BeholderProvider.github.endpoint("ExampleAlex"),
            fields: ["Display name": "Example Alex", "Public email": "example@example.com"]
        )
        model.correlation.observe(username: "ExampleAlex", finding: finding)
        try model.correlation.record(
            accountID: "github:examplealex",
            identifier: XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone)),
            source: "https://example.com/contact"
        )
        for (kind, input) in [
            (BeholderCaseSearch.Kind.name, "Example Alex"),
            (.email, "example@example.com"),
            (.phone, "+61 400 000 001"),
            (.ip, "203.0.113.1"),
        ] {
            let discovery = BeholderDiscovery(model)
            discovery.kind = kind; discovery.query = input; discovery.search()
            let size = CGSize(width: 760, height: 620)
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                Text("FIND BY " + kind.rawValue.uppercased()).font(.headline)
                if kind != .ip {
                    BeholderPublicSearchView(input: .init(value: input, kind: kind, region: .international), ownerTyped: true)
                }
                BeholderCaseSearchView(discovery: discovery, onReview: { _ in })
            }.padding(20).frame(width: size.width, height: size.height).foregroundStyle(HUD.ink)
                .background(HUD.void).environment(\.colorScheme, .dark))
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let name = kind.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("beholder-discovery-" + name + ".png"))
        }
    }
}

private struct NoDiscoveryNetwork: BeholderSearching {
    func lookup(_ provider: BeholderProvider, username _: String) async -> BeholderFinding {
        XCTFail("Local discovery must not start a lookup")
        return BeholderFinding(provider: provider, status: .unavailable)
    }
}

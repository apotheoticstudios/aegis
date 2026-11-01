@testable import Aegis
import AppKit
import SwiftUI
import XCTest

final class BeholderInvestigationRenderTests: XCTestCase {
    @MainActor func testPersonOverviewAndCandidateSavingLayouts() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1"
        else { throw XCTSkip("Opt-in invented person overview layouts") }
        let model = BeholderModel(client: OverviewNoNetwork())
        let alex = try model.people.create("Example Alex"), jamie = try model.people.create("Example Jamie")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let email = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for person in [alex, jamie] {
            try model.correlation.identify(personID: person, identifier: email, source: "https://example.com/author", now: date)
        }
        let finding = BeholderFinding(
            provider: .github,
            status: .candidate,
            checkedAt: date,
            sourceURL: BeholderProvider.github.endpoint("ExampleAlex"),
            fields: ["Display name": "Example Alex", "Public email": email.value, "Bio": "Example public author"]
        )
        model.correlation.observe(username: "ExampleAlex", finding: finding)
        try model.people.link(
            personID: alex,
            username: "ExampleAlex",
            finding: finding,
            assessment: .supported,
            reason: "Example author page links this account",
            evidence: "https://example.com/author",
            now: date
        )
        var possible = finding; possible.sourceURL = BeholderProvider.github.endpoint("ExampleOther")
        try model.savePossible(personID: alex, username: "ExampleOther", finding: possible)
        for (name, size, view) in [
            (
                "person-compact",
                CGSize(width: 868, height: 520),
                AnyView(BeholderPeopleView(research: model, personID: alex, embedded: true))
            ),
            ("person-wide", CGSize(width: 1300, height: 760), AnyView(BeholderPeopleView(research: model, personID: alex, embedded: true))),
            ("save-possible", CGSize(width: 868, height: 620), AnyView(BeholderResultsView(
                findings: [finding], username: "ExampleAlex", searching: false, research: model, onLink: { _ in }
            ))),
        ] {
            let host = NSHostingView(rootView: view.padding(16).frame(width: size.width, height: size.height)
                .foregroundStyle(HUD.ink).background(HUD.void).environment(\.colorScheme, .dark))
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("beholder-" + name + ".png"))
        }
    }
}

private struct OverviewNoNetwork: BeholderSearching {
    func lookup(_ provider: BeholderProvider, username _: String) async -> BeholderFinding {
        XCTFail("Overview rendering must never request data")
        return BeholderFinding(provider: provider, status: .unavailable)
    }
}

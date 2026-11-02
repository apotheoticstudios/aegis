@testable import Aegis
import AppKit
import SwiftUI
import XCTest

final class BeholderGitHubRenderTests: XCTestCase {
    @MainActor func testSyntheticGitHubDiscoveryLayouts() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1"
        else { throw XCTSkip("Opt-in synthetic GitHub discovery layouts") }
        let model = BeholderModel(discoveryClient: GitHubRenderFixture())
        let discovery = model.githubDiscovery
        try await render(BeholderDashboard(research: model), name: "empty", height: 650)
        discovery.kind = .email
        discovery.value = "example+tag@example.com"
        discovery.chooseGitHub()
        try await render(BeholderDashboard(research: model), name: "prepared", height: 650)
        discovery.search()
        try await finish { discovery.searching }
        try await render(BeholderDashboard(research: model), name: "hits", height: 650)
        try model.people.create("Example Alex")
        try discovery.inspect(XCTUnwrap(discovery.page?.hits.first), into: model)
        try await finish { discovery.inspecting != nil }
        try await render(
            BeholderGitHubDiscoveryView(discovery: discovery, research: model, onReview: { _ in }),
            name: "profile",
            height: 1000
        )
        XCTAssertEqual(model.correlation.accounts.count, 1)
        XCTAssertTrue(model.people.people.flatMap(\.links).isEmpty)
    }

    @MainActor private func render(_ view: some View, name: String, height: CGFloat) async throws {
        let size = CGSize(width: 900, height: height)
        let host = NSHostingView(rootView: view.padding(16).frame(width: size.width, height: size.height)
            .foregroundStyle(HUD.ink).background(HUD.void).environment(\.colorScheme, .dark))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("beholder-github-" + name + ".png"))
    }

    @MainActor private func finish(while busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy())
    }
}

private struct GitHubRenderFixture: BeholderGitHubDiscovering {
    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        .success(.init(
            request: request, hits: [.init(login: "ExampleAlex"), .init(login: "ExampleOther")],
            total: 25, incomplete: true, checkedAt: .init(timeIntervalSince1970: 1_790_000_000)
        ))
    }

    func inspect(_ login: String) async -> BeholderFinding {
        .init(
            provider: .github, status: .candidate, checkedAt: .init(timeIntervalSince1970: 1_790_000_000),
            sourceURL: BeholderProvider.github.endpoint(login),
            fields: ["Handle": login, "Account type": "User", "Display name": "Example Alex", "Bio": "Example public author"]
        )
    }
}

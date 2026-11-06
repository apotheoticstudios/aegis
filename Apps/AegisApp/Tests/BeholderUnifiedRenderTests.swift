@testable import Aegis
import AppKit
import SwiftUI
import XCTest

final class BeholderUnifiedRenderTests: XCTestCase {
    @MainActor func testUnifiedSearchLayouts() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1"
        else { throw XCTSkip("Opt-in synthetic unified search layouts") }
        let model = BeholderModel(client: UnifiedRenderFixture(), discoveryClient: UnifiedRenderFixture())
        try await render(model, name: "empty")
        let personID = try model.people.create("Example Alex")
        model.unifiedSearch.query = "Example"
        model.unifiedSearch.prepare()
        try await render(model, name: "ambiguous")
        model.unifiedSearch.query = "Example Alex"
        model.unifiedSearch.prepare(); model.unifiedSearch.chooseGitHub()
        try await render(model, name: "name-preview")
        model.githubDiscovery.search()
        try await finish { model.githubDiscovery.searching }
        try await render(model, name: "name-hits")
        model.unifiedSearch.query = "@ExampleAlex"
        model.unifiedSearch.prepare(); model.selected = [.github]
        model.unifiedSearch.searchProfiles(in: model)
        try await finish { model.searching }
        try await render(model, name: "username")
        try await render(model, name: "username-wide", width: 1300, height: 900)
        for index in 0 ..< 7 {
            let handle = "ExamplePage\(index)"
            let finding = await UnifiedRenderFixture().lookup(.github, username: handle)
            model.correlation.observe(username: handle, finding: finding)
        }
        model.unifiedSearch.query = "Example Alex"; model.unifiedSearch.prepare()
        try await render(model, name: "saved-pages")
        try await render(model, name: "investigation-sheet", personID: personID)
        model.unifiedSearch.query = "0400 000 001"
        try await render(model, name: "phone-region")
        model.unifiedSearch.region = .australia; model.unifiedSearch.prepare()
        try await render(model, name: "phone")
        model.unifiedSearch.query = "203.0.113.1"; model.unifiedSearch.prepare()
        try await render(model, name: "ip")
    }

    @MainActor private func render(
        _ model: BeholderModel, name: String, width: CGFloat = 900, height: CGFloat = 650, personID: UUID? = nil
    ) async throws {
        let size = CGSize(width: width, height: height)
        let view = if let personID {
            AnyView(BeholderInvestigationSheet(research: model, personID: personID))
        } else {
            AnyView(BeholderDashboard(research: model))
        }
        let host = NSHostingView(rootView: view.padding(16).frame(width: width, height: height)
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
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("beholder-unified-" + name + ".png"))
    }

    @MainActor private func finish(_ busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy())
    }
}

private struct UnifiedRenderFixture: BeholderSearching, BeholderGitHubDiscovering {
    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        .init(
            provider: provider,
            status: .candidate,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000),
            sourceURL: provider.endpoint(username),
            fields: ["Handle": username, "Account type": "User", "Display name": "Example Alex"]
        )
    }

    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        .success(.init(
            request: request,
            hits: [.init(login: "ExampleAlex"), .init(login: "ExampleOther")],
            total: 2,
            incomplete: false,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000)
        ))
    }

    func inspect(_ login: String) async -> BeholderFinding {
        await lookup(.github, username: login)
    }
}

@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Native layout checks for the combined workspace; the client returns invented records without a transport.
final class BeholderWorkspaceRenderTests: XCTestCase {
    @MainActor func testAllSourcesAndPersonNotesRenderAtCompactAndWideSizes() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in synthetic combined workspace render.")
        }
        let model = BeholderModel(client: WorkspaceFixtures())
        model.query = "ExampleAlex"
        model.selected = Set(BeholderProvider.allCases)
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.searching, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.findings.count, BeholderProvider.allCases.count)
        let candidate = try XCTUnwrap(model.findings.first { $0.provider == .github })
        let person = try model.people.create("Example Alex")
        try model.people.link(
            personID: person,
            username: "ExampleAlex",
            finding: candidate,
            assessment: .supported,
            reason: "The public author page links to this profile.",
            evidence: "https://example.com/author"
        )
        for (name, size, panel) in [
            ("workspace-compact", CGSize(width: 900, height: 650), false),
            ("workspace-wide", CGSize(width: 1400, height: 900), false),
            // Panel-aware dashboard layout only; this does not exercise HUDShell or panel focus.
            ("workspace-panel-aware", CGSize(width: 900, height: 650), true),
        ] {
            try capture(model, size: size, name: name, panel: panel)
        }
        let imported = BeholderModel(client: WorkspaceFixtures())
        try imported.importCase(model.export())
        try capture(imported, size: CGSize(width: 900, height: 650), name: "workspace-imported")
        let running = BeholderModel(client: WorkspaceFixtures())
        running.query = "ExamplePending"; running.selected = Set(BeholderProvider.allCases); running.start()
        XCTAssertTrue(running.searching)
        try capture(running, size: CGSize(width: 900, height: 650), name: "workspace-running")
        running.cancel()
    }

    @MainActor private func capture(_ model: BeholderModel, size: CGSize, name: String, panel: Bool = false) throws {
        let host = NSHostingView(rootView: BeholderDashboard(research: model, followsPanel: panel)
            .frame(width: size.width, height: size.height).background(HUD.void).environment(\.colorScheme, .dark))
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
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-\(name).png"))
    }
}

private actor WorkspaceFixtures: BeholderSearching {
    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        let status: BeholderFinding.Status = switch provider {
        case .github: .candidate
        case .gitlab: .noResult
        case .hackerNews: .limited
        default: .unavailable
        }
        return BeholderFinding(
            provider: provider,
            status: status,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000),
            sourceURL: provider.endpoint(username),
            fields: status == .candidate ? ["Handle": username] : [:]
        )
    }
}

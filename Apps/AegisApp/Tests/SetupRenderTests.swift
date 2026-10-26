@testable import Aegis
import AegisKit
import AppKit
import SwiftUI
import XCTest

/// Renders every setup step to a PNG with a synthetic Mac and the sample core service, to compare with the design
/// system's WizStep screens. Opt-in: `TEST_RUNNER_AEGIS_RENDER_SETUP=<folder>`.
@MainActor
final class SetupRenderTests: XCTestCase {
    func testRendersEveryStep() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_RENDER_SETUP"] else {
            throw XCTSkip("Set AEGIS_RENDER_SETUP to a folder to render the setup steps.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        setup.wizard.useRecommendedForRest()
        setup.wizard.next()
        let app = SetupApp(model: PanelModel(service: SampleCoreService(), actions: nil), wake: WakeListener(), hotKey: "⌥Space")
        for index in setup.wizard.steps.indices {
            setup.wizard.go(to: index)
            let view = NSHostingView(rootView: SetupView(setup: setup, app: app, finish: {}, later: {}))
            view.frame = CGRect(origin: .zero, size: SetupWindow.size)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = String(format: "step%02d.png", index + 1)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
    }
}

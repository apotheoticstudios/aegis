@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Opt-in visual checks of the voice bar, using synthetic words only.
@MainActor
final class HUDVoiceOverlayTests: XCTestCase {
    func testRendersTheVoiceOverlay() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_RENDER_VOICE"] else {
            throw XCTSkip("Set AEGIS_RENDER_VOICE to a folder to render the voice overlay.")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wasShowing = HUDPresence.shared.shell
        HUDPresence.shared.shell = true
        defer { HUDPresence.shared.shell = wasShowing }

        func snap(_ state: HUDVoiceOverlay.State, reduced: Bool = false) throws {
            let view = HUDVoiceOverlay(
                state: state,
                transcript: "What is next on the sample schedule?",
                answer: "The sample design review starts at eleven. There is time to prepare.",
                meta: state == .answering ? "read > synthetic calendar · 2 events" : nil,
                name: "aegis",
                typed: 0.6
            )
            .environment(\.accessibilityReduceMotion, reduced)
            .padding(24)
            .frame(width: 568, height: 240, alignment: .top)
            .background(HUD.void)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 568, height: 240)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            // Let the 420 ms arrival finish before capturing the bar.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let suffix = reduced ? "-reduced" : ""
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("voice-\(state.rawValue)\(suffix).png"))
        }

        for state in HUDVoiceOverlay.State.allCases {
            try snap(state)
        }
        try snap(.answering, reduced: true)
    }
}

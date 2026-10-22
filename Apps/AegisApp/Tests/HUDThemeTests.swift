@testable import Aegis
import AppKit
import Foundation
import SwiftUI
import XCTest

/// The design system's own rules (ADR-0029), held for every theme, and its fonts, bundled with their licences.
final class HUDThemeTests: XCTestCase {
    func testEveryThemeDefinesEveryToken() {
        for theme in HUDTheme.allCases {
            for token in HUDToken.allCases {
                XCTAssertNotEqual(theme.rgba(token), 0xFF00_FFFF, "\(theme) lacks \(token)")
            }
        }
    }

    /// Text holds 4.5:1 and meaningful edges 3:1 on the void and every surface, glass included; text on a fill holds
    /// 4.5:1 on it.
    func testContrastOnEveryGround() {
        for theme in HUDTheme.allCases {
            let grounds = [rgb(theme.rgba(.void)), rgb(theme.rgba(.surface)), rgb(theme.rgba(.surfaceRaised)), glass(theme)]
            for ground in grounds {
                for token in [HUDToken.ink, .inkMuted, .primary, .accent, .ok, .warn, .critical] {
                    XCTAssertGreaterThanOrEqual(contrast(rgb(theme.rgba(token)), ground), 4.5, "\(theme): \(token)")
                }
                for token in [HUDToken.frame, .focus] {
                    XCTAssertGreaterThanOrEqual(contrast(rgb(theme.rgba(token)), ground), 3, "\(theme): \(token)")
                }
            }
            XCTAssertGreaterThanOrEqual(contrast(rgb(theme.rgba(.onPrimary)), rgb(theme.rgba(.primary))), 4.5, "\(theme)")
            XCTAssertGreaterThanOrEqual(contrast(rgb(theme.rgba(.onAccent)), rgb(theme.rgba(.accent))), 4.5, "\(theme)")
        }
    }

    /// Every type style's face is in the app and registers, so no style falls back to the system font.
    func testEveryTypeStyleHasItsBundledFace() throws {
        _ = HUDFonts.registered
        let bundled = try XCTUnwrap(Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Fonts"))
        let styles: [HUDType] = [
            .display, .title, .label, .body, .bodyStrong, .caption, .readoutXL, .readout, .data, .term, .ascii, .pixelTitle,
            .terminal,
        ]
        for style in styles {
            XCTAssertTrue(bundled.contains { $0.deletingPathExtension().lastPathComponent == style.fontName }, style.fontName)
            XCTAssertEqual(NSFont(name: style.fontName, size: style.size)?.fontName, style.fontName)
        }
    }

    /// Each Open Font License face ships its family's licence; Xirod is public domain (CC0) and needs none.
    func testEveryBundledFontShipsItsLicence() throws {
        let bundled = try XCTUnwrap(Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Fonts"))
        let names = Set(bundled.map(\.lastPathComponent))
        for font in bundled where ["ttf", "woff2"].contains(font.pathExtension) && !font.lastPathComponent.hasPrefix("Xirod") {
            let family = font.lastPathComponent.split(separator: "-")[0]
            XCTAssertTrue(names.contains("\(family)-OFL.txt"), "\(font.lastPathComponent) has no licence")
        }
    }

    private func rgb(_ value: UInt32) -> [Double] {
        [24, 16, 8].map { HUDTheme.channel(value, $0) }
    }

    /// Glass as it shows: the glass token composited over the void.
    private func glass(_ theme: HUDTheme) -> [Double] {
        let alpha = HUDTheme.channel(theme.rgba(.surfaceGlass), 0)
        return zip(rgb(theme.rgba(.surfaceGlass)), rgb(theme.rgba(.void))).map { alpha * $0 + (1 - alpha) * $1 }
    }

    /// The WCAG contrast ratio.
    private func contrast(_ first: [Double], _ second: [Double]) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.040_45 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

/// The panel's screens drawn with the synthetic sample brief, to look at the design without opening the app or touching
/// real data: `TEST_RUNNER_AEGIS_PANEL_PREVIEW=<folder> xcodebuild … test -only-testing:AegisAppTests/PanelPreviewTests`.
/// The reactor draws only in a visible window, and nothing is measured or animated while the panel counts as closed.
@MainActor
final class PanelPreviewTests: XCTestCase {
    func testDrawsEveryScreenWithTheSampleBrief() async throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_PANEL_PREVIEW"] else {
            throw XCTSkip("Set AEGIS_PANEL_PREVIEW to a folder to draw the panel with the sample brief.")
        }
        // No weather or flight lookup: the pictures show the sample's synthetic data only.
        WorldPresence.shared.briefLines = []
        WorldPresence.shared.briefFetched = Date()
        let model = PanelModel(service: SampleCoreService(), actions: nil)
        await model.refresh()
        await model.refreshActivity()
        for screen in HUDScreen.allCases {
            try await draw(screen.view(model), to: URL(fileURLWithPath: folder).appendingPathComponent("\(screen.title).png"))
        }
        try await draw(BootScreen(model: model), to: URL(fileURLWithPath: folder).appendingPathComponent("Boot.png"))
    }

    /// The setup wizard's screens (#26), with a synthetic Mac and no file.
    func testDrawsEverySetupScreen() async throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_PANEL_PREVIEW"] else {
            throw XCTSkip("Set AEGIS_PANEL_PREVIEW to a folder to draw the setup wizard.")
        }
        let setup = SetupModel(file: nil, mac: SetupTests.sampleMac)
        for step in SetupModel.built {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("Setup-\(step.rawValue).png")
            try await draw(SetupView(setup: setup, finish: {}, later: {}), to: url)
            setup.wizard.next()
        }
    }

    private func draw(_ screen: some View, to url: URL) async throws {
        let host = NSHostingView(rootView: screen
            .padding(HUD.space6)
            .frame(width: 1360, height: 860)
            .hudType(.body)
            .foregroundStyle(HUD.ink)
            .background(HUDGround())
            .environment(\.colorScheme, .dark))
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 1360, height: 860), styleMask: .borderless, backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private extension HUDScreen {
    @MainActor func view(_ model: PanelModel) -> AnyView {
        switch self {
        case .home: AnyView(HomeScreen(model: model, screen: .constant(self)))
        case .system: AnyView(SystemScreen(model: model, screen: .constant(self)))
        case .comms: AnyView(CommsScreen(model: model, screen: .constant(self)))
        case .chat: AnyView(ChatScreen(model: model, screen: .constant(self)))
        case .logs: AnyView(LogsScreen(model: model, screen: .constant(self)))
        }
    }
}

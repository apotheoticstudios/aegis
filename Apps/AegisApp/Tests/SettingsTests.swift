@testable import Aegis
import AegisKit
import AppKit
import SwiftUI
import XCTest

/// The Settings window (#177): the find box, the footer's Undo and the permissions badge, then (opt-in) every page
/// rendered with a synthetic Mac and the sample core, to compare with the design system's Settings pages.
@MainActor
final class SettingsTests: XCTestCase {
    func testFindMatchesLabelsAndKeywordsIgnoringCase() {
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("") }, SettingsPane.allCases, "an empty box shows every page")
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("  MATRIX ") }, [.interface], "a theme's name finds Interface")
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("cesium") }, [.sources], "the World view keys are on Sources")
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("chatgpt") }, [.brain])
        XCTAssertTrue(SettingsPane.silence.matches("alerts"), "the title counts too")
        XCTAssertTrue(SettingsPane.allCases.filter { $0.matches("zzz") }.isEmpty)
    }

    func testReturnOpensTheFirstMatch() {
        let model = SettingsModel()
        model.query = "wake"
        XCTAssertEqual(model.hits.first, .personality, "rail order")
        model.openFirstHit()
        XCTAssertEqual(model.page, .personality)
        model.query = "zzz"
        model.openFirstHit()
        XCTAssertEqual(model.page, .personality, "no match leaves the page alone")
    }

    func testPagesAreNumberedAcrossTheGroups() {
        XCTAssertEqual(SettingsPane.general.number, 1)
        XCTAssertEqual(SettingsPane.reset.number, SettingsPane.allCases.count)
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.group)), Set(SettingsPane.groups))
        XCTAssertEqual(SettingsPane.allCases.map(\.group), SettingsPane.allCases.map(\.group).sorted {
            SettingsPane.groups.firstIndex(of: $0)! < SettingsPane.groups.firstIndex(of: $1)!
        }, "each group's pages sit together, in the groups' order")
    }

    func testUndoPutsTheLastChangeBack() {
        let model = SettingsModel()
        var widgets = true
        widgets = false
        model.record("Desktop widgets off", merge: nil, undo: { widgets = true })
        XCTAssertEqual(model.last?.label, "Desktop widgets off")
        XCTAssertNotNil(model.last?.at)
        model.undo()
        XCTAssertTrue(widgets)
        XCTAssertEqual(model.last?.label, "Undone")
        XCTAssertNil(model.last?.undo, "one level")
        model.undo()
        XCTAssertTrue(widgets)
    }

    func testASlidersDragUndoesToBeforeTheDrag() {
        let model = SettingsModel()
        var formality = 6
        for value in 7 ... 9 {
            let old = formality
            formality = value
            model.record("Formality \(value)", merge: "Formality", undo: { formality = old })
        }
        XCTAssertEqual(model.last?.label, "Formality 9")
        model.undo()
        XCTAssertEqual(formality, 6)
    }

    func testDifferentControlsDontMerge() {
        let model = SettingsModel()
        var log: [String] = []
        model.record("Formality 7", merge: "Formality", undo: { log.append("formality") })
        model.record("Humour 3", merge: "Humour", undo: { log.append("humour") })
        model.undo()
        XCTAssertEqual(log, ["humour"])
    }

    func testChangingPageKeepsTheLabelButNotTheUndo() {
        let model = SettingsModel()
        model.record("Theme: Matrix", merge: nil, undo: {})
        model.page = .voice
        XCTAssertEqual(model.last?.label, "Theme: Matrix")
        XCTAssertNil(model.last?.undo)
    }

    func testClosingLeavesNothingToUndo() {
        let model = SettingsModel()
        model.record("Theme: Matrix", merge: nil, undo: {})
        model.forget()
        XCTAssertNil(model.last, "a reopened window starts with \u{201C}Changes save as you make them\u{201D}")
    }

    func testMissingPermissionsCountRowsNotPermissions() {
        XCTAssertEqual(Permission.missing([:]), 3, "unknown counts as missing")
        let all = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) })
        XCTAssertEqual(Permission.missing(all), 0)
        var noReminders = all
        noReminders[.reminders] = false
        XCTAssertEqual(Permission.missing(noReminders), 1, "Calendar and Reminders is one row")
    }

    /// Renders every page to `page01.png`…, plus the find box and footer in use. Opt-in:
    /// `TEST_RUNNER_AEGIS_RENDER_SETTINGS=<folder>`.
    func testRendersEveryPage() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_RENDER_SETTINGS"] else {
            throw XCTSkip("Set AEGIS_RENDER_SETTINGS to a folder to render the Settings pages.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // The hand-off's plan switch would ask Claude Code who's signed in; previews don't.
        let plan = UserDefaults.aegis.object(forKey: CloudKeys.claudePlanKey)
        UserDefaults.aegis.set(false, forKey: CloudKeys.claudePlanKey)
        defer { UserDefaults.aegis.set(plan, forKey: CloudKeys.claudePlanKey) }
        let setup = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        let app = SetupApp(
            model: PanelModel(service: SampleCoreService(), actions: nil), wake: WakeListener(), hotKey: "⌥Space", shellKey: "⌃⌥A"
        )
        let model = SettingsModel()
        for page in SettingsPane.allCases {
            model.page = page
            try render(
                model,
                setup,
                app,
                to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "page%02d.png", page.number))
            )
        }
        model.page = .interface
        model.record("Theme: Matrix", merge: nil, undo: {})
        model.query = "theme"
        try render(model, setup, app, to: URL(fileURLWithPath: folder).appendingPathComponent("find-and-undo.png"))
    }

    private func render(_ model: SettingsModel, _ setup: SetupModel, _ app: SetupApp, to file: URL) throws {
        let view = NSHostingView(rootView: SettingsView(model: model, setup: setup, app: app, runSetup: {}, close: {}))
        view.frame = CGRect(origin: .zero, size: SetupWindow.size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)
    }
}

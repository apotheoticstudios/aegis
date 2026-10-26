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

    /// Drives the wizard in a real window with mouse and keyboard events, as the owner would, with synthetic data and
    /// a temporary setup file: every step, its controls, the rail, Back, Escape and Return. Saves a snapshot after
    /// each action. Opt-in: `TEST_RUNNER_AEGIS_DRIVE_SETUP=<folder>`.
    func testDrivesEveryStep() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEGIS_DRIVE_SETUP"] else {
            throw XCTSkip("Set AEGIS_DRIVE_SETUP to a folder to drive the wizard.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        let app = SetupApp(model: PanelModel(service: KeepingCore(), actions: nil), wake: WakeListener(), hotKey: "⌥Space")
        var finished = false
        SetupWindow.show(app, again: false, setup: setup) { finished = true }
        let driver = try SetupDriver(window: XCTUnwrap(SetupWindow.window), folder: folder)
        defer { SetupWindow.close() }
        driver.wait(2)
        driver.snap("01-welcome")

        driveMacToAddons(driver, setup)
        drivePrivacyToSilence(driver, setup, app)

        // The rail jumps back to a screen reached, and forward again.
        driver.click(95, 100.6 + 2 * 23.05, "rail-storage")
        XCTAssertEqual(setup.wizard.current, .storage)
        driver.click(95, 100.6 + 13 * 23.05, "rail-silence")
        XCTAssertEqual(setup.wizard.current, .silence)
        driver.click(95, 100.6 + 15 * 23.05, "rail-ready-locked")
        XCTAssertEqual(setup.wizard.current, .silence, "a screen not reached stays locked")
        driver.click(69, 799, "back")
        XCTAssertEqual(setup.wizard.current, .interface)

        driver.click(1054, 799, "recommended")
        XCTAssertEqual(setup.wizard.current, .tuneUp)
        driver.wait(4)
        driver.snap("15-tune-up")
        driver.key("\r", code: 36, "15-return")
        XCTAssertEqual(setup.wizard.current, .ready, "Return is Next")
        driver.wait(2)
        driver.snap("16-ready")
        driver.click(1266, 799, "open-aegis")
        XCTAssertTrue(finished, "Open Aegis finishes setup")
        XCTAssertTrue(setup.wizard.finished)
        XCTAssertFalse(SetupWindow.window?.isVisible ?? true, "the window closes")
        XCTAssertFalse(HUDPresence.shared.setup)

        let resumed = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        XCTAssertEqual(resumed.wizard.answers, setup.wizard.answers, "every answer was saved")
        XCTAssertTrue(resumed.wizard.finished)
    }

    /// Steps 2 to 9: each kind of control, from the Mac's type to an addon.
    private func driveMacToAddons(_ driver: SetupDriver, _ setup: SetupModel) {
        driver.click(1266, 799, "start")
        XCTAssertEqual(setup.wizard.current, .mac)
        driver.click(922, 351, "02-desktop")
        XCTAssertFalse(setup.wizard.mac.isLaptop, "Desktop chosen")
        XCTAssertTrue(setup.wizard.alwaysOn, "a desktop runs always on unless changed")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .storage)
        driver.drag(from: (278, 253), to: (720, 253), "03-slider-drag")
        XCTAssertGreaterThan(setup.wizard.storageGB, 150, "dragging the slider moves it")
        let dragged = setup.wizard.storageGB
        driver.drag(from: (720, 253), to: (500, 253), "03-slider-drag-back")
        XCTAssertLessThan(setup.wizard.storageGB, dragged, "and back")
        driver.click(300, 253, "03-slider-click")
        XCTAssertLessThan(setup.wizard.storageGB, 30, "a click along it sets it too")
        driver.click(857, 501, "03-keep-6")
        XCTAssertEqual(setup.wizard.answers[option: "keep"], "6")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .schedule)
        driver.click(950, 261, "04-later")
        XCTAssertEqual(setup.wizard.briefMinutes, 7 * 60 + 15)
        driver.click(916, 309, "04-wake-mac")
        XCTAssertTrue(setup.wizard.wakeMacForBrief)
        driver.click(896, 358, "04-quiet-hours")
        XCTAssertEqual(setup.wizard.answers[option: "quiet"], "hours")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .permissions)
        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .sources)
        driver.click(1306, 353, "06-photos")
        XCTAssertEqual(setup.wizard.answers[option: "source.photos"], "on")
        driver.click(762, 233, "06-messages")
        XCTAssertEqual(setup.wizard.answers[option: "source.messages"], "off")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .home)
        driver.click(926, 341, "07-lights-confirm")
        XCTAssertEqual(setup.wizard.answers[option: "device.lights"], "confirm")
        driver.click(860, 462, "07-garage-instant")
        XCTAssertNil(setup.wizard.answers[option: "device.garage"], "the garage stays on Confirm")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .control)
        driver.click(1306, 263, "08-photos")
        XCTAssertEqual(setup.wizard.answers[option: "app.Photos"], "on")
        driver.click(1259, 516, "08-send")
        XCTAssertEqual(setup.wizard.answers[option: "send"], "send")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .addons)
        driver.click(1061, 245, "09-mail")
        XCTAssertEqual(setup.wizard.answers[option: "addon.mail"], "on")
    }

    /// Steps 10 to 14: a list and a typed entry, the personality saved through the core, the voice, the theme.
    private func drivePrivacyToSilence(_ driver: SetupDriver, _ setup: SetupModel, _ app: SetupApp) {
        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .privacy)
        driver.click(340, 238, "10-remove-1password")
        XCTAssertEqual(setup.wizard.answers[option: "neverApps"], "Banking apps")
        driver.click(355, 363, "10-add-person")
        driver.type("Test Person")
        driver.key("\r", code: 36, "10-return")
        XCTAssertEqual(setup.wizard.current, .privacy, "Return in a field adds to it; it doesn't go to the next step")
        XCTAssertEqual(setup.wizard.answers[option: "neverPeople"], "Test Person")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .personality)
        driver.click(789, 224, "11-friendly")
        driver.click(824, 362, "11-sir")
        driver.click(380, 426, "11-formality")
        XCTAssertNotNil(setup.wizard.answers[option: "tone.formality"])
        driver.wait(1)
        XCTAssertEqual(app.model.personality.style, .friendly, "saved through the core")
        XCTAssertEqual(app.model.personality.callOwner, "sir")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .voice)
        driver.click(612, 334, "12-system-voice")
        XCTAssertEqual(setup.wizard.answers[option: "voiceName"], "system")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .interface)
        driver.click(732, 320, "13-matrix")
        XCTAssertEqual(UserDefaults.aegis.string(forKey: HUDTheme.storeKey), "matrix")
        driver.click(743, 379, "13-compact")
        XCTAssertEqual(setup.wizard.answers[option: "panelSize"], "compact")
        driver.click(315, 312, "13-arc")
        XCTAssertEqual(UserDefaults.aegis.string(forKey: HUDTheme.storeKey), "arc")

        driver.click(1266, 799, "next")
        XCTAssertEqual(setup.wizard.current, .silence)
        driver.click(916, 269, "14-break-silence")
        XCTAssertEqual(setup.wizard.answers[option: "breakSilence"], "on")
    }

    /// Opens the wizard for trying by hand, with synthetic data and a temporary setup file (your real setup is left
    /// alone), until it finishes or the file `AEGIS_TRY_SETUP` names appears; at most 30 minutes. Opt-in.
    func testTryWizard() throws {
        guard let stop = ProcessInfo.processInfo.environment["AEGIS_TRY_SETUP"] else {
            throw XCTSkip("Set AEGIS_TRY_SETUP to a stop-file path to try the wizard by hand.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        let app = SetupApp(model: PanelModel(service: KeepingCore(), actions: nil), wake: WakeListener(), hotKey: "⌥Space")
        var finished = false
        SetupWindow.show(app, again: false, setup: setup) { finished = true }
        let driver = try SetupDriver(window: XCTUnwrap(SetupWindow.window), folder: nil)
        let deadline = Date().addingTimeInterval(30 * 60)
        while !finished, Date() < deadline, !FileManager.default.fileExists(atPath: stop), SetupWindow.window?.isVisible == true {
            driver.wait(0.2)
        }
        SetupWindow.close()
    }

    /// Escape closes setup where it is; showing it again resumes there.
    func testEscapeClosesAndResumes() throws {
        guard ProcessInfo.processInfo.environment["AEGIS_DRIVE_SETUP"] != nil else {
            throw XCTSkip("Set AEGIS_DRIVE_SETUP to a folder to drive the wizard.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        let app = SetupApp(model: PanelModel(service: SampleCoreService(), actions: nil), wake: WakeListener(), hotKey: nil)
        SetupWindow.show(app, again: false, setup: setup) {}
        let driver = try SetupDriver(window: XCTUnwrap(SetupWindow.window), folder: nil)
        driver.wait(1)
        driver.click(1266, 799, "start")
        driver.click(1266, 799, "next")
        driver.key("\u{1b}", code: 53, "escape")
        XCTAssertFalse(SetupWindow.window?.isVisible ?? true, "Escape closes setup")
        XCTAssertFalse(HUDPresence.shared.setup)
        let resumed = SetupModel(file: SetupFile(url: url), mac: SetupTests.sampleMac)
        XCTAssertEqual(resumed.wizard.current, .storage)
    }
}

/// Sends mouse and keyboard events to a window, as the owner's would arrive, at points measured from its top left.
@MainActor
private struct SetupDriver {
    let window: NSWindow
    let folder: String?

    /// Runs the app as its own loop does: takes each queued event and sends it, for `seconds`.
    func wait(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    func click(_ across: CGFloat, _ down: CGFloat, _ name: String) {
        send(.leftMouseDown, at: (across, down))
        send(.leftMouseUp, at: (across, down))
        settle(name)
    }

    func drag(from start: (CGFloat, CGFloat), to end: (CGFloat, CGFloat), _ name: String) {
        send(.leftMouseDown, at: start)
        for step in 1 ... 12 {
            let share = CGFloat(step) / 12
            send(.leftMouseDragged, at: (start.0 + (end.0 - start.0) * share, start.1 + (end.1 - start.1) * share))
        }
        send(.leftMouseUp, at: end)
        settle(name)
    }

    func type(_ text: String) {
        for character in text {
            key(String(character), code: 0, nil)
        }
    }

    func key(_ characters: String, code: UInt16, _ name: String?) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        if let name {
            settle(name)
        } else {
            wait(0.05)
        }
    }

    func snap(_ name: String) {
        guard let folder, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    private func settle(_ name: String) {
        wait(0.6)
        snap(name)
    }

    private func send(_ type: NSEvent.EventType, at point: (CGFloat, CGFloat)) {
        let location = NSPoint(x: point.0, y: window.frame.height - point.1)
        if let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ) {
            NSApp.postEvent(event, atStart: false)
        }
        wait(0.03)
    }
}

/// The sample core, except that it keeps the personality it's given, as AegisCore does.
private actor KeepingCore: CoreService {
    private let sample = SampleCoreService()
    private var kept = Personality.standard

    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case let .setPersonality(personality):
            kept = personality
            return .personality(personality)
        case .personality:
            return .personality(kept)
        default:
            return await sample.handle(request)
        }
    }
}

import AegisKit
import AppKit
import SwiftUI

/// The setup wizard on screen (#26): AegisKit's wizard, saved after every change so setup resumes where it stopped.
@MainActor @Observable
final class SetupModel {
    /// The screens built so far; the others join as they're built (the plan's stages 3 and 4).
    static let built: [SetupStep] = [.welcome, .mac, .storage, .schedule, .permissions, .ready]

    var wizard: SetupWizard {
        didSet { save() }
    }

    private let file: SetupFile?

    init(file: SetupFile? = SetupModel.standardFile, mac: MacProfile = .detect()) {
        self.file = file
        var wizard = (try? file?.load()) ?? SetupWizard(mac: mac)
        // Free space changes between runs; the rest was detected (or corrected by the owner) before.
        wizard.mac.diskFreeBytes = mac.diskFreeBytes
        wizard.steps = Self.built
        self.wizard = wizard
    }

    /// Setup has been finished once on this Mac.
    static var finished: Bool {
        (try? standardFile?.load())?.finished == true
    }

    /// `~/Library/Application Support/Aegis/setup.json`, beside AegisCore's files.
    static let standardFile: SetupFile? = {
        guard let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Aegis", isDirectory: true),
            (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        return SetupFile(url: folder.appendingPathComponent("setup.json"))
    }()

    private func save() {
        // shortcut: an unwritable file only loses progress (setup starts again next launch), so it isn't reported.
        try? file?.save(wizard)
    }
}

/// The wizard's window: the HUD's own frame as its edge, like the panel, at the normal window level so System
/// Settings can come in front of it while the owner grants access.
@MainActor
enum SetupWindow {
    private static var window: NSWindow?

    /// Shows setup where it stopped, or from the start when `again` (from the menu); `done` runs when it finishes.
    static func show(service: any CoreService, again: Bool, done: @escaping () -> Void) {
        let setup = SetupModel()
        if again {
            setup.wizard.restart()
        }
        let created = window ?? HUDWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.borderless], backing: .buffered, defer: true
        )
        created.isReleasedWhenClosed = false
        // A panel hides when Aegis isn't active; the wizard stays while the owner is in System Settings.
        created.hidesOnDeactivate = false
        created.isMovableByWindowBackground = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.contentView = NSHostingView(rootView: SetupView(
            setup: setup,
            finish: {
                let minutes = setup.wizard.briefMinutes
                Task { _ = await service.handle(.setBriefTime(minutes: minutes)) }
                close()
                done()
            },
            later: close
        ))
        window = created
        NSApp.activate()
        created.center()
        created.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
    }
}

/// The wizard: one screen at a time in the HUD's shell, the step and progress along the top, Back, "Use recommended
/// for the rest" and Next along the bottom (DESIGN.md "Wizard rules").
struct SetupView: View {
    @Bindable var setup: SetupModel
    let finish: () -> Void
    let later: () -> Void

    var body: some View {
        let wizard = setup.wizard
        HUDShell {
            Text("Aegis setup").hudType(.title).foregroundStyle(HUD.frame)
            Spacer()
            HUDMeter(
                label: "Step \(wizard.position + 1) of \(wizard.steps.count)",
                value: Double(wizard.position + 1) / Double(wizard.steps.count), display: "", size: .small
            )
            .frame(width: 220)
            Button("Later", action: later).buttonStyle(HUDChipStyle(muted: true)).help("Close setup; it resumes here next time")
        } content: {
            SetupScreen(setup: setup).id(wizard.current)
        } bottom: {
            HStack(spacing: HUD.space4) {
                if wizard.canGoBack {
                    Button("Back") { setup.wizard.back() }.buttonStyle(HUDPlateStyle())
                }
                Spacer()
                if wizard.current != .ready {
                    Button(wizard.current == .welcome ? "Use recommended for everything" : "Use recommended for the rest") {
                        setup.wizard.useRecommendedForRest()
                    }
                    .buttonStyle(HUDPlateStyle())
                }
                Button(wizard.current == .welcome ? "Start" : wizard.current == .ready ? "Open Aegis" : "Next") {
                    let last = wizard.current == .ready
                    setup.wizard.next()
                    if last {
                        finish()
                    }
                }
                .buttonStyle(HUDPlateStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 1040, height: 680)
        .hudType(.body)
        .foregroundStyle(HUD.ink)
        .padding(HUD.strokeFrame)
        .background(HUDGround())
        .clipShape(HUDCut(kind: .panel, cut: HUD.chamferLg))
        .environment(\.colorScheme, .dark)
    }
}

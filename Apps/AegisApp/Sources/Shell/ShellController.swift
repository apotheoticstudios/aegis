import AegisKit
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// AegisShell (DESIGN.md › AegisShell, ADR-0033): on demand only, it hides the Dock, keeps macOS's own menu bar with
/// Aegis's item in it, and puts a live HUD on the desktop under every window; disengaging puts macOS back as it was.
/// Nothing here runs while it's off: no windows, no timers.
@MainActor @Observable
final class ShellController {
    static let shared = ShellController()

    enum Phase: Equatable {
        case off, engaging(Date), engaged, leaving(Date)
    }

    var phase = Phase.off
    /// From 900 ms into engaging, the Aegis menu bar item shows the workspace, the status and Exit.
    var itemComplete = false
    /// What the desktop shows round the core, refreshed while engaged.
    var readings = Readings()
    /// The Dock couldn't be hidden: Aegis isn't allowed to control System Events.
    private(set) var dockProblem = false

    struct Readings: Equatable {
        var urgent = 0
        var events: [HUDScheduleArc.Event] = []
        var now = Date()
    }

    /// The app's panel model and actions, set at launch.
    @ObservationIgnored var model: PanelModel?
    @ObservationIgnored var openPanel: () -> Void = {}
    @ObservationIgnored var talk: () -> Void = {}
    /// The panel's own shortcuts, for the menu.
    @ObservationIgnored var panelKey: String?
    @ObservationIgnored var talkKey: String?

    @ObservationIgnored private let settings = ShellSettings(
        dock: SystemDock(), file: WorldSidecar.folder.deletingLastPathComponent().appendingPathComponent("shell-state.json")
    )
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var items: ShellMenuBarItems?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var screens: (any NSObjectProtocol)?

    /// Engaging, engaged or leaving: Aegis's own item replaces the everyday menu bar icon.
    var isOn: Bool {
        phase != .off
    }

    /// ⌃⌥A, the design's shortcut; nil when another app holds it.
    private(set) var hotKeyLabel: String?

    /// At launch: the shortcut, and macOS put back if Aegis quit while engaged (a crash).
    func start() {
        guard !WorldSidecar.isTestHost else { return }
        let choice = GlobalHotKey.Choice(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥A")
        hotKey = GlobalHotKey(choice, number: 3) { [weak self] in self?.toggle() }
        hotKeyLabel = hotKey == nil ? nil : choice.label
        if settings.saved != nil {
            Task { await settings.restore() }
        }
    }

    func toggle() {
        switch phase {
        case .off: Task { await engage() }
        case .engaging, .engaged: disengage()
        case .leaving: break
        }
    }

    /// What Aegis says to "engage" and "stand down".
    func handle(_ command: ShellCommand) async -> String {
        switch command {
        case .engage:
            guard phase == .off else { return "AegisShell is already engaged." }
            await engage()
            return dockProblem
                ? "Engaged, but the Dock stays: allow Aegis to control System Events in System Settings › Privacy & Security › Automation."
                : "AegisShell engaged."
        case .disengage:
            guard phase != .off else { return "AegisShell isn't engaged." }
            disengage()
            return "Standing down."
        }
    }

    func engage() async {
        guard phase == .off, !WorldSidecar.isTestHost else { return }
        let start = Date()
        phase = .engaging(start)
        itemComplete = false
        HUDPresence.shared.shell = true
        items = ShellMenuBarItems(shell: self)
        openWindows()
        await refreshReadings()
        dockProblem = await !(settings.apply())
        refresher = Task { [weak self] in
            // The NOW mark moves each minute; the schedule and the brief are read again every five.
            var minute = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                minute += 1
                guard let self, !Task.isCancelled else { return }
                if minute.isMultiple(of: 5) {
                    await refreshReadings()
                } else {
                    readings.now = Date()
                }
            }
        }
        await settle(start, at: ShellMotion.itemShows) { $0.itemComplete = true }
        await settle(start, at: ShellMotion.engaged) { shell in
            if case .engaging = shell.phase {
                shell.phase = .engaged
            }
        }
    }

    func disengage() {
        switch phase {
        case .engaging, .engaged: break
        default: return
        }
        let start = Date()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        phase = .leaving(start)
        refresher?.cancel()
        Task {
            await settle(start, at: reduced ? 0 : ShellMotion.dockReturns) { _ in }
            await settings.restore()
            await settle(start, at: reduced ? ShellMotion.reduced : ShellMotion.disengaged) { $0.finish() }
        }
    }

    /// Aegis is quitting: macOS goes back at once.
    func shutDown() {
        guard phase != .off || settings.saved != nil else { return }
        finish()
        settings.restoreNow()
    }

    private func finish() {
        guard phase != .off else { return }
        phase = .off
        refresher?.cancel()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        items?.remove()
        items = nil
        HUDPresence.shared.shell = false
        if let screens {
            NotificationCenter.default.removeObserver(screens)
        }
        screens = nil
    }

    /// Runs `change` `delay` seconds after `start`, if the phase hasn't moved on meanwhile.
    private func settle(_ start: Date, at delay: Double, _ change: (ShellController) -> Void) async {
        let wait = delay - Date().timeIntervalSince(start)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
        switch phase {
        case let .engaging(began) where began == start, let .leaving(began) where began == start: change(self)
        default: break
        }
    }

    private func refreshReadings() async {
        guard let model else { return }
        await model.checkForNewBrief()
        let now = Date(), day = Calendar.current.startOfDay(for: now)
        var events: [HUDScheduleArc.Event] = []
        if case let .schedule(occurrences, _) = await model.service.handle(.schedule(from: day, to: day.addingTimeInterval(86400))) {
            events = occurrences.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
                .map { HUDScheduleArc.Event(start: $0.start, end: $0.end, title: $0.title) }
        }
        readings = Readings(
            urgent: model.stored?.brief.items.count { $0.priority == .urgent } ?? 0, events: events, now: now
        )
    }

    /// One desktop window per display, above Finder's icons and below every app's windows, on every Space. It takes
    /// clicks, so nothing reaches the hidden icons beneath, without ever becoming the active app.
    private func openWindows() {
        windows = NSScreen.screens.map { screen in
            let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            let top = screen.frame.maxY - screen.visibleFrame.maxY
            window.contentView = NSHostingView(rootView: ShellDesktop(shell: self, size: screen.frame.size, top: top))
            window.setFrame(screen.frame, display: false)
            window.orderFront(nil)
            return window
        }
        // A display added, removed or rearranged: the desktop follows.
        screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                self.windows.forEach { $0.orderOut(nil) }
                self.windows = []
                if let screens = self.screens {
                    NotificationCenter.default.removeObserver(screens)
                }
                self.openWindows()
            }
        }
    }
}

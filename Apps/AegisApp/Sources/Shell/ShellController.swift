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
        struct Waiting: Equatable {
            let name: String
            let since: Date
        }

        /// One line of the stream: when, from where, what, and what it says with details hidden.
        struct Line: Equatable {
            let time: Date
            let source: String
            let text: String
            let hidden: String
            var urgent = false
        }

        var urgent = 0
        var stream: [Line] = []
        /// Today's weather at home, as the brief words it ("Weather at home: 18 to 27°. Rain likely from 3 pm."); nil
        /// without a home or with the World view's lines switched off.
        var weather: String?
        /// Events collected since midnight.
        var today = 0
        /// The first urgent item: its line, and whether it came from a person.
        var top: String?
        var topFromPerson = false
        var items = 0
        var events: [HUDScheduleArc.Event] = []
        var waiting: [Waiting] = []
        /// Sources that need a fix.
        var problems: [SourceKind] = []
        var diskUsed: UInt64 = 0
        var diskTotal: UInt64 = 0
        /// Aegis's own processes.
        var memory: UInt64 = 0
        var now = Date()
    }

    /// Counts and kinds instead of names and words. On by default until screen sharing can be detected; the owner
    /// turns it off in Aegis's menu. Kept across launches.
    var hideDetails = UserDefaults.aegis.object(forKey: "shellHideDetails") as? Bool ?? true {
        didSet { UserDefaults.aegis.set(hideDetails, forKey: "shellHideDetails") }
    }

    /// The desktop held still by the owner's choice.
    var holdStill = UserDefaults.aegis.bool(forKey: "shellHoldStill") {
        didSet {
            UserDefaults.aegis.set(holdStill, forKey: "shellHoldStill")
            checkStill()
        }
    }

    /// Why the desktop holds still, or nil while it's live.
    var still: ShellStill?

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
    @ObservationIgnored private let dockQueue = ShellQueue()
    @ObservationIgnored private var screens: (any NSObjectProtocol)?
    @ObservationIgnored private var occlusion: [any NSObjectProtocol] = []

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
        checkStill()
        // The Dock drops away first, as the design's engage begins.
        await dock { $0.dockProblem = await !($0.settings.apply()) }
        // Disengaged meanwhile: nothing more to start.
        guard engaging(since: start) else { return }
        await refreshReadings()
        guard engaging(since: start) else { return }
        refresher = Task { [weak self] in
            // Whether to hold still every 10 s; the NOW mark each minute; everything else every five.
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                tick += 1
                guard let self, !Task.isCancelled else { return }
                checkStill()
                if tick.isMultiple(of: 30) {
                    await refreshReadings()
                } else if tick.isMultiple(of: 6) {
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
        ShellLauncher.shared.close(returning: false)
        Task {
            await settle(start, at: reduced ? 0 : ShellMotion.dockReturns) { _ in }
            await dock { await $0.settings.restore() }
            await settle(start, at: reduced ? ShellMotion.reduced : ShellMotion.disengaged) { $0.finish() }
        }
    }

    private func engaging(since start: Date) -> Bool {
        if case let .engaging(began) = phase {
            return began == start
        }
        return false
    }

    /// Dock changes run one after another, so a restore always follows any hide still under way: disengaging in the
    /// middle of engaging can't leave the Dock hidden or lose the saved setting.
    private func dock(_ work: @escaping @MainActor (ShellController) async -> Void) async {
        await dockQueue.run { [weak self] in
            if let self {
                await work(self)
            }
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
        occlusion.forEach(NotificationCenter.default.removeObserver)
        occlusion = []
        still = nil
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
        var next = Readings(now: now)
        if case let .schedule(occurrences, _) = await model.service.handle(.schedule(from: day, to: day.addingTimeInterval(86400))) {
            next.events = occurrences.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
                .map { HUDScheduleArc.Event(start: $0.start, end: $0.end, title: $0.title, location: $0.location) }
        }
        let items = model.stored?.brief.items ?? []
        let urgent = items.filter { $0.priority == .urgent }
        next.urgent = urgent.count
        next.top = urgent.first?.text
        next.topFromPerson = urgent.first?.person != nil
        next.items = items.count
        let urgentEvents = Set(urgent.flatMap(\.eventIDs))
        if case let .events(recent) = await model.service.handle(.recentEvents(limit: 14)) {
            next.stream = recent.map { Self.line($0, urgent: urgentEvents.contains($0.id)) }
        }
        if case let .activity(activity) = await model.service.handle(.activity(hours: 24)) {
            next.today = activity.counts.values.reduce(0) { sum, hours in
                sum + hours.enumerated().filter { activity.start.addingTimeInterval(Double($0.offset) * 3600) >= day }
                    .reduce(0) { $0 + $1.element }
            }
        }
        if case let .people(people) = await model.service.handle(.people) {
            next.waiting = people.sorted { $0.waitingSince < $1.waitingSince }.map { .init(name: $0.person.name, since: $0.waitingSince) }
        }
        if case let .status(status) = await model.service.handle(.status) {
            next.problems = SourceHealth.lines(status.sources, now: now).filter { $0.state != .healthy }.map(\.source)
        }
        next.weather = await Self.weather()
        let system = await Task.detached(priority: .utility) {
            var reader = SystemReader()
            return reader.read(processes: true)
        }.value
        (next.diskUsed, next.diskTotal) = (system.diskUsed, system.diskTotal)
        next.memory = system.processes.filter(\.aegis).reduce(0) { $0 + $1.memory }
        readings = next
    }

    /// Today's forecast for home, home rounded to about 10 km (ADR-0024), when the owner allows the World lines.
    private static func weather() async -> String? {
        guard WorldPresence.briefEnabled, let home = WorldHome.point,
              let url = WorldBrief.weatherURL(latitude: home.latitude, longitude: home.longitude)
        else { return nil }
        let session = URLSession(configuration: .ephemeral) // privacy-guard: allow-network rounded home forecast, ADR-0024
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return WorldBrief.weather(data, now: Date())
    }

    /// A stream line from an event: the sender and the first line of what it says, or its kind with details hidden.
    static func line(_ event: Event, urgent: Bool) -> Readings.Line {
        let (source, hidden) = switch event.source {
        case .imessage, .sms: ("messages", "Message from a contact")
        case .email: ("mail", "Mail from a sender")
        case .notification: ("notice", "A notification")
        }
        let said = (event.title.map { $0 + " · " } ?? "") + (event.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
        let text = event.sender.map { $0 + ": " + said } ?? said
        return .init(time: event.eventTime, source: source, text: String(text.prefix(140)), hidden: hidden, urgent: urgent)
    }

    /// Holds the desktop still on battery, when the Mac is hot, under Reduce Motion, by choice, or while every display's
    /// desktop is covered.
    func checkStill() {
        guard isOn else { return }
        let covered = !windows.isEmpty && windows.allSatisfy { !$0.occlusionState.contains(.visible) }
        still = ShellStill.reason(
            battery: ShellStill.onBattery, thermal: ProcessInfo.processInfo.thermalState,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, held: holdStill, covered: covered
        )
    }

    /// One desktop window per display, above Finder's icons and below every app's windows, on every Space. It takes
    /// clicks, so nothing reaches the hidden icons beneath, without ever becoming the active app.
    private func openWindows() {
        windows = NSScreen.screens.map { screen in
            let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            // See-through until the wall fades in, so engaging and leaving cross-fade with the wallpaper.
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            let top = screen.frame.maxY - screen.visibleFrame.maxY
            window.contentView = NSHostingView(rootView: ShellDesktop(shell: self, size: screen.frame.size, top: top))
            window.setFrame(screen.frame, display: false)
            // Left out of screenshots and screen sharing where macOS honours it; hiding details covers the rest.
            window.sharingType = .none
            window.orderFront(nil)
            occlusion.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkStill() }
            })
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
                self.occlusion.forEach(NotificationCenter.default.removeObserver)
                self.occlusion = []
                if let screens = self.screens {
                    NotificationCenter.default.removeObserver(screens)
                }
                self.openWindows()
            }
        }
    }
}

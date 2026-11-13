import AegisKit
import AppKit
import SwiftUI

/// AegisShell's bar over the whole of macOS's menu bar while it's engaged (owner's choices, 2026-11-12 and 2026-11-13;
/// ADR-0033). One borderless panel per menu bar, just above macOS's own status items and under its menus: the front
/// app's menus are reached by their shortcuts, and Aegis draws its own right side. Nothing hides or changes the menu
/// bar itself, and full-screen apps keep theirs.
@MainActor
final class ShellMenuBar: NSObject {
    private let shell: ShellController
    private let status = ShellSystemStatus()
    private var bars: [NSPanel] = []
    private var menu: NSPanel?
    private var outside: [Any] = []
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    init(shell: ShellController) {
        self.shell = shell
        super.init()
        status.start()
        place()
        // A display added, removed or rearranged, or a Space whose menu bar shows or hides: the bars follow.
        let follow: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (.default, NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: follow
            )),
            (
                workspace,
                workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: follow)
            ),
        ]
    }

    /// Where a display's bar goes, and the room either side of the notch (each half of a display without one).
    struct Layout: Equatable {
        let frame: NSRect
        let left: CGFloat
        let right: CGFloat
    }

    /// Across a display's whole menu bar. Nil where no menu bar takes room (one that hides itself, or a second display
    /// without its own), so the bar never covers a window's buttons.
    static func layout(screen: NSRect, visible: NSRect, notchLeft: NSRect?, notchRight: NSRect?) -> Layout? {
        let height = screen.maxY - visible.maxY
        guard height > 0 else { return nil }
        return Layout(
            frame: NSRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height),
            left: notchLeft?.width ?? screen.width / 2,
            right: notchRight?.width ?? screen.width / 2
        )
    }

    private func place() {
        let layouts = NSScreen.screens.compactMap {
            Self.layout(
                screen: $0.frame,
                visible: $0.visibleFrame,
                notchLeft: $0.auxiliaryTopLeftArea,
                notchRight: $0.auxiliaryTopRightArea
            )
        }
        guard layouts.map(\.frame) != bars.map(\.frame) else { return }
        // With no menu bar to sit on, Aegis's everyday icon stays as the way out (in a menu bar that slides down).
        shell.barShown = !layouts.isEmpty
        closeMenu()
        bars.forEach { $0.orderOut(nil) }
        bars = layouts.map { layout in
            let frame = layout.frame
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // Over macOS's own status items (at the status bar's level), under its menus.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            // On every Space but not beside full-screen apps, still in Mission Control, out of the window cycle.
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ShellBar(
                shell: shell, status: status, left: layout.left, right: layout.right,
                menu: { [weak self] in self?.toggleMenu() }, close: { [weak self] in self?.closeMenu() }
            ))
            panel.setFrame(frame, display: false)
            panel.orderFront(nil)
            return panel
        }
    }

    /// Takes the bars out of the menu bar.
    func remove() {
        closeMenu()
        status.stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        bars.forEach { $0.orderOut(nil) }
        bars = []
        shell.barShown = false
    }

    private func toggleMenu() {
        if menu != nil {
            return closeMenu()
        }
        // Under the hexagon of the bar that was clicked (the first, when it came from VoiceOver rather than a click).
        guard let bar = bars.first(where: { $0 === NSApp.currentEvent?.window }) ?? bars.first else { return }
        let content = NSHostingView(rootView: ShellMenu(shell: shell) { [weak self] in self?.closeMenu() })
        let size = content.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(x: bar.frame.minX + 6, y: bar.frame.minY - size.height - 4, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = content
        panel.orderFront(nil)
        menu = panel
        // A click anywhere else closes it, as a menu does: in another app, or in Aegis's own windows (the desktop).
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        outside = [
            NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeMenu() }
            } as Any,
            NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                MainActor.assumeIsolated {
                    // The bar's own controls close or toggle it themselves.
                    if let self, event.window !== self.menu, !self.bars.contains(where: { $0 === event.window }) {
                        self.closeMenu()
                    }
                }
                return event
            } as Any,
        ]
    }

    private func closeMenu() {
        menu?.orderOut(nil)
        menu = nil
        outside.forEach(NSEvent.removeMonitor)
        outside = []
    }
}

/// The bar itself, on the void so it melts into the desktop: left of the notch, the hexagon with the status word, the
/// hidden mark and an urgent count (it opens ShellMenu), the workspaces, the launcher and Talk, and Exit; right of it,
/// the readings (`ShellBarReadings`). It takes the menu bar's own type, so it reads like the menus it covers; only the
/// hexagon, the pips and the dot carry the theme's colour. Where the full row doesn't fit, it folds (`Fit`).
struct ShellBar: View {
    let shell: ShellController
    let status: ShellSystemStatus
    /// The room left and right of the notch: nothing is drawn behind it.
    let left: CGFloat
    let right: CGFloat
    let menu: () -> Void
    let close: () -> Void
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        // It arrives and leaves with the desktop's wash, so the void never shows over the wallpaper on its own.
        TimelineView(.animation(paused: !moving)) { context in
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    controls(.full)
                    controls(.folded)
                    controls(.least)
                }
                .frame(width: left, alignment: .leading)
                Spacer(minLength: 0)
                ShellBarReadings(shell: shell, status: status, close: close).frame(width: right, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color(.void))
            .opacity(arrived(at: context.date))
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .foregroundStyle(.white)
        .lineLimit(1)
        .environment(\.hudTheme, theme)
        .environment(\.colorScheme, .dark)
    }

    private var moving: Bool {
        switch shell.phase {
        case .engaging, .leaving: true
        case .off, .engaged: false
        }
    }

    private func arrived(at date: Date) -> Double {
        switch shell.phase {
        case let .engaging(start):
            let frame = ShellMotion.engage(date.timeIntervalSince(start), reduced: still)
            return frame.all * frame.wall
        case let .leaving(start): return ShellMotion.disengage(date.timeIntervalSince(start), reduced: still).all
        case .off, .engaged: return 1
        }
    }

    /// How much of the row fits: all of it; the workspaces folded to their pips; or, on the narrowest menu bar, only the
    /// hexagon and Exit, so the way out is never cut off (the menu still has everything).
    enum Fit {
        case full, folded, least
    }

    private func controls(_ fit: Fit) -> some View {
        HStack(spacing: 2) {
            identity
            if shell.itemComplete {
                if fit != .least {
                    divider
                    ForEach(ShellWorkspace.allCases, id: \.self) { workspace in
                        workspaceButton(workspace, named: fit == .full || workspace == shell.workspace)
                    }
                    divider
                    button("Launcher", help: Self.help("Launcher", shell.panelKey)) { ShellLauncher.shared.open() }
                    button("Talk", icon: .mic, help: Self.help("Talk", shell.talkKey)) { shell.talk() }
                }
                divider
                button("Exit", icon: .power, help: Self.help("Disengage AegisShell", shell.hotKeyLabel)) { shell.disengage() }
            }
        }
        .fixedSize()
        .padding(.leading, 8)
    }

    /// The hexagon, filled and glowing, with the status word: Aegis's menu.
    private var identity: some View {
        let status = ShellStatus(shell)
        let urgent = shell.model?.glow == true ? shell.readings.urgent : 0
        return Button(action: menu) {
            HStack(spacing: 7) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !status.breathes || still)) { context in
                    ShellGlyph(filled: true)
                        .foregroundStyle(theme.color(urgent > 0 ? .critical : .primary))
                        .shadow(color: theme.color(urgent > 0 ? .critical : .primary), radius: urgent > 0 ? 5 : 3)
                        .opacity(status.breathes && !still ? HUDMotion.breathe(context.date.timeIntervalSinceReferenceDate * 2) : 1)
                }
                if shell.itemComplete {
                    HStack(spacing: 5) {
                        Rectangle().fill(theme.color(status.tone)).frame(width: 5, height: 5)
                            .shadow(color: status.live ? theme.color(.primary) : .clear, radius: 5)
                        Text(status.word)
                    }
                    .opacity(0.86)
                }
                if shell.hideDetails {
                    ShellIconView(icon: .hidden, size: 13).opacity(0.86)
                }
                if urgent > 0 {
                    HStack(spacing: 4) {
                        ShellIconView(icon: .alert, size: 11)
                        Text("\(urgent)").fontWeight(.semibold)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(theme.color(.critical))
                }
            }
            .modifier(BarItem())
        }
        .buttonStyle(ShellRowStyle())
        .accessibilityLabel(
            "Aegis: \(status.word)" + (shell.hideDetails ? ", details hidden" : "") + (urgent > 0 ? ", \(urgent) urgent" : "")
        )
        .accessibilityHint("Opens AegisShell's menu")
    }

    /// A workspace: its pip and name, the one showing underlined in its accent; folded, the others are just their pips.
    private func workspaceButton(_ workspace: ShellWorkspace, named: Bool) -> some View {
        let chosen = workspace == shell.workspace
        let accent = theme.color(workspace.accent)
        return Button {
            close()
            shell.switchTo(workspace)
        } label: {
            HStack(spacing: 5) {
                Rectangle().fill(accent).frame(width: 6, height: 6)
                if named {
                    Text(workspace.name)
                }
            }
            .opacity(chosen ? 1 : 0.62)
            .modifier(BarItem())
            .overlay(alignment: .bottom) {
                if chosen {
                    Rectangle().fill(accent).frame(height: 2).shadow(color: accent, radius: 3)
                }
            }
        }
        .buttonStyle(ShellRowStyle())
        .help(Self.help(workspace.name, shell.workspaceKeyLabels[workspace]))
        .accessibilityLabel("\(workspace.name) workspace")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// "Focus (⌃2)": a control's name and its shortcut, if it has one.
    static func help(_ name: String, _ keys: String?) -> String {
        keys.map { "\(name) (\($0))" } ?? name
    }

    private func button(_ title: String, icon: ShellIcon? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    ShellIconView(icon: icon, size: 12)
                }
                Text(title)
            }
            .modifier(BarItem())
        }
        .buttonStyle(ShellRowStyle())
        .help(help)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 14).padding(.horizontal, 6)
    }
}

/// A bar control's room: as tall as macOS's own menu highlight, a little padding either side.
struct BarItem: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
    }
}

/// The status word and its tone, from one vocabulary.
struct ShellStatus {
    let word: String
    let tone: HUDToken
    /// Listening and speaking: the hexagon breathes.
    let breathes: Bool

    var live: Bool {
        tone == .primary
    }

    @MainActor
    init(_ shell: ShellController) {
        let model = shell.model
        if case .engaging = shell.phase {
            (word, tone, breathes) = ("Engaging", .primary, false)
        } else if case .unavailable = model?.phase {
            (word, tone, breathes) = ("Offline", .critical, false)
        } else if case .asking = model?.askState {
            (word, tone, breathes) = ("Thinking", .primary, false)
        } else if model?.voice.speaking == true {
            (word, tone, breathes) = ("Speaking", .primary, true)
        } else if model?.voice.isListening == true {
            (word, tone, breathes) = ("Listening", .primary, true)
        } else {
            (word, tone, breathes) = ("Online", .ok, false)
        }
    }
}

/// Aegis's hexagon: an outline round a smaller hexagon, filled while AegisShell is engaged.
struct ShellGlyph: View {
    var filled: Bool
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 16
            func hexagon(_ points: [(Double, Double)]) -> Path {
                Path { path in
                    path.addLines(points.map { CGPoint(x: $0.0 * scale, y: $0.1 * scale) })
                    path.closeSubpath()
                }
            }
            let outer = hexagon([(8, 1.2), (14, 4.6), (14, 11.4), (8, 14.8), (2, 11.4), (2, 4.6)])
            let inner = hexagon([(8, 4.6), (11, 6.3), (11, 9.7), (8, 11.4), (5, 9.7), (5, 6.3)])
            context.stroke(outer, with: .foreground, lineWidth: 1.4 * scale)
            context.stroke(inner, with: .foreground, lineWidth: 1.4 * scale)
            if filled {
                context.fill(inner, with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The menu under the bar's hexagon (the design system's ShellMenu), its own glass panel rather than a native menu: the
/// emblem, name and status; the urgent item; the workspaces with their shortcuts; the launcher, the panel and Talk; the
/// privacy switches; and Disengage.
struct ShellMenu: View {
    let shell: ShellController
    let close: () -> Void
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @State private var banner: [String] = []

    var body: some View {
        let status = ShellStatus(shell)
        let shape = HUDCut(kind: .panel, cut: HUD.chamferSm)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HUD.space2) {
                HUDEmblem(size: 20)
                let cols = banner.map(\.count).max() ?? 0
                HUDAsciiText(lines: banner, cols: cols, size: Self.bannerSize(cols: cols), tone: HUD.primary)
                Spacer(minLength: 0)
                HUDTag(word: status.word, tone: HUDColor(token: status.live ? .primary : status.tone)).fixedSize()
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
            .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
            if shell.readings.urgent > 0, shell.model?.glow == true {
                HStack(spacing: HUD.space2) {
                    ShellIconView(icon: .alert, size: 12)
                    Text("\(shell.readings.urgent) urgent").hudCaps(10, tracking: 0.16)
                    Text(shell.hideDetails ? "Open the panel to see" : shell.readings.top ?? "Open the panel to see")
                        .hudType(.body).foregroundStyle(HUD.ink).lineLimit(1)
                }
                .foregroundStyle(HUD.critical)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
            }
            Text("Workspace").hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
            ForEach(ShellWorkspace.allCases, id: \.self) { workspace in
                ShellWorkspaceRow(workspace: workspace, keys: shell.workspaceKeyLabels[workspace], chosen: workspace == shell.workspace) {
                    close()
                    shell.switchTo(workspace)
                }
            }
            Text("Aegis").hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
            row("Launcher", keys: shell.panelKey) { ShellLauncher.shared.open() }
            row("Open the panel", keys: nil) { shell.openPanel() }
            row("Talk to \(shell.model?.personality.name ?? "Aegis")", keys: shell.talkKey) { shell.talk() }
            Text("Privacy").hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
            toggle("Hide details", on: Binding(get: { shell.hideDetails }, set: { shell.hideDetails = $0 }))
            toggle("Hold the desktop still", on: Binding(get: { shell.holdStill }, set: { shell.holdStill = $0 }))
            HStack {
                Button {
                    close()
                    shell.disengage()
                } label: {
                    Label { Text("Disengage") } icon: { ShellIconView(icon: .power, size: 14) }
                }
                .buttonStyle(HUDPlateStyle(compact: true))
                Spacer()
                if let key = shell.hotKeyLabel {
                    HUDKeyCaps(keys: ShellMenu.caps(key))
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            .overlay(alignment: .top) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
            .padding(.top, 8)
        }
        .padding(.top, 6)
        // Leading, so a row that's ever too wide is cut at the right instead of shifting the whole menu.
        .frame(width: 320, alignment: .leading)
        .background {
            ZStack {
                VisualEffect().clipShape(shape)
                shape.fill(theme.color(.surface).opacity(0.95))
                shape.fill(LinearGradient(
                    colors: [theme.color(.glassSheen), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.3)
                ))
            }
        }
        .overlay(shape.strokeBorder(HUD.frame, lineWidth: 1))
        .clipShape(shape)
        .foregroundStyle(HUD.ink)
        .environment(\.hudTheme, theme)
        .environment(\.colorScheme, .dark)
        .task { banner = HUDBanner.lines(shell.model?.personality.name ?? "Aegis", rows: 10) }
        .onExitCommand(perform: close)
    }

    private func toggle(_ title: String, on: Binding<Bool>) -> some View {
        HStack {
            Text(title).hudType(.body)
            Spacer()
            HUDToggle(on: on, label: title, showState: false)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
    }

    /// The name banner's character size: as designed, but small enough that a long name leaves the status tag room in
    /// the 320-point menu.
    static func bannerSize(cols: Int, width: CGFloat = 150) -> CGFloat {
        cols == 0 ? 2.4 : min(2.4, width / (CGFloat(cols) * HUDAscii.cellAspect))
    }

    /// "⌥⇧Space" as key caps: each modifier, then the key.
    static func caps(_ label: String) -> [String] {
        let modifiers = label.prefix { "⌃⌥⇧⌘".contains($0) }
        return modifiers.map(String.init) + [String(label.dropFirst(modifiers.count))]
    }

    private func row(_ title: String, keys: String?, action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            HStack {
                Text(title).hudType(.body)
                Spacer()
                if let keys {
                    HUDKeyCaps(keys: ShellMenu.caps(keys))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellRowStyle())
    }
}

/// A workspace in the menu: its accent pip, its name (ticked when it's the one showing) and its shortcut; the one showing
/// carries an accent edge.
private struct ShellWorkspaceRow: View {
    let workspace: ShellWorkspace
    let keys: String?
    let chosen: Bool
    let choose: () -> Void
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let accent = theme.color(workspace.accent)
        Button(action: choose) {
            HStack(spacing: HUD.space2) {
                Rectangle().fill(accent).frame(width: 6, height: 6)
                Text(workspace.name).hudType(.body)
                if chosen {
                    Text("✓").font(HUDFace.mono(12)).foregroundStyle(HUD.ok)
                }
                Spacer()
                if let keys {
                    HUDKeyCaps(keys: ShellMenu.caps(keys))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background {
                if chosen {
                    LinearGradient(
                        stops: [.init(color: accent.opacity(0.16), location: 0), .init(color: .clear, location: 0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .overlay(alignment: .leading) {
                if chosen {
                    Rectangle().fill(accent).frame(width: 2).shadow(color: accent, radius: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellRowStyle())
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A menu row lifts to the raised surface under the pointer.
struct ShellRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellRow(configuration: configuration)
    }
}

struct ShellRow: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(HUD.surfaceRaised.opacity(hovering || configuration.isPressed ? 1 : 0))
            .onHover { hovering = $0 }
    }
}

/// The blur behind the menu's glass.
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

/// The small line icons AegisShell's controls use (the design system's ShellIcon): 16-point paths, 1.5 stroke,
/// square caps, mitred joins, chamfers instead of curves.
enum ShellIcon: String {
    case power, alert, mic, hidden, wifi, wired, offline, bolt

    var commands: String {
        switch self {
        case .power: "M5 4.5 L3.5 6.5 V10 L6 13 H10 L12.5 10 V6.5 L11 4.5 M8 2 V8"
        case .alert: "M8 1.8 L15 14 H1 Z M8 6 V10 M8 11.5 V12.5"
        case .mic: "M6 2 H10 V9 L9 10 H7 L6 9 Z M3.5 7.5 V9.5 L6 12 H10 L12.5 9.5 V7.5 M8 12 V14.5"
        case .hidden: "M1.5 8 L4 5 L8 3.8 L12 5 L14.5 8 L12 11 L8 12.2 L4 11 Z M2.5 14 L13.5 2"
        case .wifi: "M1.5 6.5 L4.5 3.5 H11.5 L14.5 6.5 M4 9.5 L6 7.5 H10 L12 9.5 M7 12 H9 V13.5 H7 Z"
        case .wired: "M3 3.5 H13 V10 L11 12.5 H5 L3 10 Z M6 6 V8 M8 6 V8 M10 6 V8"
        case .offline: "M1.5 6.5 L4.5 3.5 H11.5 L14.5 6.5 M4 9.5 L6 7.5 H10 L12 9.5 M7 12 H9 V13.5 H7 Z M2.5 14.5 L13.5 1.5"
        case .bolt: "M9.5 1.5 L4 9 H8 L6.5 14.5 L12 7 H8 Z"
        }
    }

    /// The path in a 16-point box, from the design's SVG commands (M, L, H, V, Z, absolute).
    func shape(scale: CGFloat) -> Path {
        var path = Path(), current = CGPoint.zero
        let tokens = Self.tokens(commands)
        var index = 0
        func number() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0) * scale
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M": current = CGPoint(x: number(), y: number())
                path.move(to: current)
            case "L": current = CGPoint(x: number(), y: number())
                path.addLine(to: current)
            case "H": current.x = number()
                path.addLine(to: current)
            case "V": current.y = number()
                path.addLine(to: current)
            default: path.closeSubpath()
            }
        }
        return path
    }

    private static func tokens(_ commands: String) -> [String] {
        commands.replacingOccurrences(of: #"([MLHVZ])"#, with: " $1 ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }
}

struct ShellIconView: View {
    let icon: ShellIcon
    var size: CGFloat = 16

    var body: some View {
        icon.shape(scale: size / 16)
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .square, lineJoin: .miter))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

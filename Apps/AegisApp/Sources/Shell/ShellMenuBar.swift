import AegisKit
import AppKit
import SwiftUI

/// Aegis's item in macOS's own menu bar while AegisShell is on (the design system's ShellMenuExtra): the hexagon,
/// filled and glowing, then the workspace with its pip, the status word with its dot and an urgent count; beside it an
/// always-visible Exit. Two status items, so each is an ordinary menu bar button macOS highlights itself.
@MainActor
final class ShellMenuBarItems: NSObject {
    private let exit = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let main = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let shell: ShellController
    private var menu: NSPanel?
    private var outside: [Any] = []

    init(shell: ShellController) {
        self.shell = shell
        super.init()
        if let button = exit.button {
            button.image = ShellIcon.image(.power, size: 12)
            button.imagePosition = .imageLeading
            button.title = "Exit"
            button.toolTip = "Disengage AegisShell" + (shell.hotKeyLabel.map { " (\($0))" } ?? "")
            button.target = self
            button.action = #selector(leave)
        }
        exit.isVisible = false
        if let button = main.button {
            let host = SizedHostingView(rootView: ShellMenuExtra(shell: shell))
            host.resized = { [weak self, weak shell] width in
                self?.main.length = width
                self?.exit.isVisible = shell?.itemComplete == true
            }
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            main.length = host.intrinsicContentSize.width
            button.target = self
            button.action = #selector(toggleMenu)
            button.setAccessibilityLabel("Aegis")
        }
    }

    /// Takes both items out of the menu bar.
    func remove() {
        closeMenu()
        NSStatusBar.system.removeStatusItem(main)
        NSStatusBar.system.removeStatusItem(exit)
    }

    @objc private func leave() {
        closeMenu()
        shell.disengage()
    }

    @objc private func toggleMenu() {
        if menu != nil {
            return closeMenu()
        }
        guard let button = main.button, let window = button.window else { return }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        let content = NSHostingView(rootView: ShellMenu(shell: shell) { [weak self] in self?.closeMenu() })
        let size = content.fittingSize
        // Right-aligned under the item, 320 wide, as the design hangs it.
        let panel = NSPanel(
            contentRect: NSRect(x: item.maxX - size.width, y: item.minY - size.height - 4, width: size.width, height: size.height),
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
                    // The item's own click toggles it.
                    if let self, event.window !== self.menu, event.window !== self.main.button?.window {
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

/// A hosting view that tells its owner when its content's width changes, and lets clicks through to the menu bar
/// button underneath.
private final class SizedHostingView<Content: View>: NSHostingView<Content> {
    var resized: (CGFloat) -> Void = { _ in }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        resized(intrinsicContentSize.width)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// The item itself: it takes the menu bar's own type and colour so it sits among the other items; only the hexagon,
/// the pip and the dot carry the theme's colour.
struct ShellMenuExtra: View {
    let shell: ShellController
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let status = ShellStatus(shell)
        let urgent = shell.model?.glow == true ? shell.readings.urgent : 0
        HStack(spacing: 7) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !status.breathes || still)) { context in
                ShellGlyph(filled: true)
                    .foregroundStyle(theme.color(urgent > 0 ? .critical : .primary))
                    .shadow(color: theme.color(urgent > 0 ? .critical : .primary), radius: urgent > 0 ? 5 : 3)
                    .opacity(status.breathes && !still ? HUDMotion.breathe(context.date.timeIntervalSinceReferenceDate * 2) : 1)
            }
            if shell.itemComplete {
                HStack(spacing: 5) {
                    Rectangle().fill(theme.color(shell.workspace.accent)).frame(width: 6, height: 6)
                    Text(shell.workspace.name)
                }
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
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 17)
                .background(theme.color(.critical), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Aegis: \(shell.workspace.name), \(status.word)" + (shell.hideDetails ? ", details hidden" : "")
                + (urgent > 0 ? ", \(urgent) urgent" : "")
        )
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

/// The menu under Aegis's item (the design system's ShellMenu), its own glass panel rather than a native menu: the
/// emblem, name and status; the urgent count; the panel; and Disengage. Workspaces, the launcher, arranging, window
/// layouts and the privacy switches join it with their stages.
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
private struct ShellRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellRow(configuration: configuration)
    }
}

private struct ShellRow: View {
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
    case power, alert, mic, hidden

    var commands: String {
        switch self {
        case .power: "M5 4.5 L3.5 6.5 V10 L6 13 H10 L12.5 10 V6.5 L11 4.5 M8 2 V8"
        case .alert: "M8 1.8 L15 14 H1 Z M8 6 V10 M8 11.5 V12.5"
        case .mic: "M6 2 H10 V9 L9 10 H7 L6 9 Z M3.5 7.5 V9.5 L6 12 H10 L12.5 9.5 V7.5 M8 12 V14.5"
        case .hidden: "M1.5 8 L4 5 L8 3.8 L12 5 L14.5 8 L12 11 L8 12.2 L4 11 Z M2.5 14 L13.5 2"
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

    /// A template image for a menu bar button.
    @MainActor
    static func image(_ icon: ShellIcon, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let path = NSBezierPath(cgPath: icon.shape(scale: size / 16).cgPath)
            path.lineWidth = 1.5 * size / 16
            path.lineCapStyle = .square
            path.lineJoinStyle = .miter
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
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

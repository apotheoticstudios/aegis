import AegisKit
import AppKit
import SwiftUI

/// AegisShell's one command bar (the design system's Launcher): ⌥Space while engaged opens it a third of the way down
/// the screen over a dimmed desktop, standing in for Spotlight and Launchpad. Apps, files and settings open through
/// the action safety system like any command (ADR-0031); anything else is asked of Aegis in the panel.
@MainActor @Observable
final class ShellLauncher {
    static let shared = ShellLauncher()

    struct Row: Equatable, Identifiable {
        enum Kind: String {
            case app = "App", file = "File", setting = "Set", command = "Cmd", ask = "Ask"
        }

        let kind: Kind
        let title: String
        var meta: String?
        /// What opening it does: an app's URL, a file's path, a settings page's name, or the words to ask.
        let target: String

        var id: String {
            kind.rawValue + target
        }
    }

    struct Group: Equatable {
        let title: String
        let rows: [Row]
    }

    var query = "" {
        didSet {
            if query != oldValue {
                search()
            }
        }
    }

    private(set) var groups: [Group] = []
    var selected = 0
    /// Nothing on the Mac matched what was typed.
    private(set) var nothing = false

    @ObservationIgnored private var window: NSPanel?
    @ObservationIgnored private var scrims: [NSWindow] = []
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var previous: NSRunningApplication?

    var isOpen: Bool {
        window != nil
    }

    var rows: [Row] {
        groups.flatMap(\.rows)
    }

    func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard window == nil, let screen = NSScreen.main else { return }
        previous = NSWorkspace.shared.frontmostApplication
        query = ""
        search()
        // The desktop dims under a scrim on every display; macOS's menu bar stays clear.
        scrims = NSScreen.screens.map { display in
            let frame = display.visibleFrame.union(NSRect(
                x: display.frame.minX,
                y: display.frame.minY,
                width: display.frame.width,
                height: 1
            ))
            let scrim = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            scrim.level = .modalPanel
            scrim.isOpaque = false
            scrim.backgroundColor = .clear
            scrim.isReleasedWhenClosed = false
            scrim.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            scrim.contentView = NSHostingView(rootView: LauncherScrim { [weak self] in self?.close() })
            scrim.orderFrontRegardless()
            return scrim
        }
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LauncherView(launcher: self))
        // A third of the way down, centred.
        let top = screen.frame.maxY - screen.frame.height / 3
        panel.setFrame(NSRect(x: screen.frame.midX - 340, y: top - 480, width: 680, height: 480), display: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = panel
    }

    func close(returning: Bool = true) {
        searching?.cancel()
        window?.orderOut(nil)
        window = nil
        scrims.forEach { $0.orderOut(nil) }
        scrims = []
        if returning {
            previous?.activate()
        }
        previous = nil
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + step + rows.count) % rows.count
    }

    /// Return: the selected row. ⌘Return: ask Aegis whatever was typed.
    func choose(ask: Bool = false) {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let row = ask ? (typed.isEmpty ? nil : Row(kind: .ask, title: typed, target: typed)) : rows[safe: selected] else { return }
        close(returning: row.kind == .ask || row.kind == .command ? false : true)
        let shell = ShellController.shared
        Task {
            switch row.kind {
            case .ask, .command:
                shell.openPanel()
                await shell.model?.submit(row.target)
            case .app:
                await shell.model?.launch(.openApp(name: URL(fileURLWithPath: row.target).deletingPathExtension().lastPathComponent))
            case .file:
                await shell.model?.launch(.openFile(path: row.target))
            case .setting:
                await shell.model?.launch(.automate(.settingsPage, argument: row.target))
            }
        }
    }

    func speak() {
        close(returning: false)
        ShellController.shared.talk()
    }

    // MARK: - Results

    private func search() {
        searching?.cancel()
        selected = 0
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        groups = Self.groups(typed, apps: Self.apps(matching: typed), files: [])
        nothing = false
        guard typed.count >= 2 else { return }
        // Files come from Spotlight, by name only, a moment after typing settles.
        searching = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let files = await PanelModel.files(named: typed)
            guard let self, !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == typed else { return }
            groups = Self.groups(typed, apps: Self.apps(matching: typed), files: files)
            nothing = groups.allSatisfy { $0.rows.allSatisfy { $0.kind == .ask } }
        }
    }

    /// The groups for what was typed: apps, files, settings, a command if it reads as one, and asking Aegis; with
    /// nothing typed, a few suggestions.
    static func groups(_ typed: String, apps: [URL], files: [String]) -> [Group] {
        guard !typed.isEmpty else {
            return [Group(title: "Suggested", rows: [
                Row(kind: .ask, title: "What's left on today?", meta: "Ask Aegis", target: "What's left on today?"),
                Row(kind: .ask, title: "What did I miss?", meta: "Ask Aegis", target: "What did I miss?"),
            ])]
        }
        let home = NSHomeDirectory()
        var result: [Group] = []
        let appRows = apps.prefix(4).map {
            Row(kind: .app, title: $0.deletingPathExtension().lastPathComponent, meta: $0.deletingLastPathComponent().path, target: $0.path)
        }
        if !appRows.isEmpty {
            result.append(Group(title: "Apps", rows: appRows))
        }
        let fileRows = files.prefix(4).map { path in
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return Row(
                kind: .file, title: URL(fileURLWithPath: path).lastPathComponent,
                meta: folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder, target: path
            )
        }
        if !fileRows.isEmpty {
            result.append(Group(title: "Files", rows: fileRows))
        }
        let settings = SettingsPage.pages.filter { $0.name.localizedCaseInsensitiveContains(typed) }.prefix(3)
            .map { Row(kind: .setting, title: $0.name, meta: "System Settings", target: $0.name) }
        if !settings.isEmpty {
            result.append(Group(title: "Settings", rows: Array(settings)))
        }
        if CommandPlan.looksLikeCommand(typed) {
            result.append(Group(title: "Commands", rows: [Row(kind: .command, title: typed, meta: "Aegis", target: typed)]))
        }
        result.append(Group(title: "Ask Aegis", rows: [Row(kind: .ask, title: typed, target: typed)]))
        return result
    }

    /// Apps whose names start with what was typed, then ones that contain it.
    static func apps(matching typed: String, in folders: [String] = appFolders) -> [URL] {
        guard !typed.isEmpty else { return [] }
        let all = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        let name = { (url: URL) in url.deletingPathExtension().lastPathComponent }
        let starts = all.filter { name($0).lowercased().hasPrefix(typed.lowercased()) }
        let contains = all.filter { !starts.contains($0) && name($0).localizedCaseInsensitiveContains(typed) }
        return starts.sorted { name($0).count < name($1).count } + contains
    }

    static let appFolders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The launcher's window takes the keyboard while it shows.
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// The desktop dimmed behind the launcher; a click on it closes the launcher.
private struct LauncherScrim: View {
    let close: () -> Void
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        theme.color(.void).opacity(0.6)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .ignoresSafeArea()
    }
}

/// The bar: the prompt, the input set large, the mic and esc; grouped results with their kind codes; key hints along
/// the foot.
struct LauncherView: View {
    @Bindable var launcher: ShellLauncher
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @FocusState private var focused: Bool
    @State private var opened = Date()

    var body: some View {
        let shape = HUDCut(kind: .panel, cut: HUD.chamferMd)
        VStack(spacing: 0) {
            bar
            Rectangle().fill(HUD.glassEdge).frame(height: 1)
            results
            Rectangle().fill(HUD.glassEdge).frame(height: 1)
            foot
        }
        .frame(width: 680)
        .background {
            ZStack {
                shape.fill(theme.color(.surface).opacity(0.92))
                shape.fill(LinearGradient(
                    colors: [theme.color(.glassSheen), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.3)
                ))
            }
        }
        .overlay(shape.strokeBorder(HUD.frame, lineWidth: 1))
        .clipShape(shape)
        .shadow(color: theme.color(.primary).opacity(theme.glow * 0.8), radius: 12)
        .modifier(LauncherArrival(opened: opened))
        .frame(width: 680, height: 480, alignment: .top)
        .environment(\.hudTheme, theme)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { launcher.move(1)
            return .handled
        }
        .onKeyPress(.upArrow) { launcher.move(-1)
            return .handled
        }
        .onKeyPress(.escape) { launcher.close()
            return .handled
        }
    }

    private var bar: some View {
        HStack(spacing: HUD.space3) {
            Text("›").font(HUDFace.mono(22)).foregroundStyle(HUD.primary).hudGlow()
            TextField("", text: $launcher.query, prompt: Text("Open, find, run or ask anything").foregroundStyle(HUD.inkMuted))
                .textFieldStyle(.plain)
                .font(.custom(HUDType.body.fontName, size: 18))
                .foregroundStyle(HUD.ink)
                .focused($focused)
                .onSubmit { launcher.choose(ask: NSEvent.modifierFlags.contains(.command)) }
            Button { launcher.speak() } label: {
                ShellIconView(icon: .mic, size: 16).foregroundStyle(HUD.inkMuted)
                    .frame(width: 30, height: 30)
                    .background(HUD.surface)
                    .overlay(Rectangle().strokeBorder(HUD.frame, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speak")
            HUDKeyCaps(keys: ["esc"])
        }
        .padding(.horizontal, HUD.space4)
        .frame(height: 56)
    }

    @ViewBuilder private var results: some View {
        if launcher.nothing {
            VStack(alignment: .leading, spacing: HUD.space3) {
                Text("Nothing on this Mac matches “\(launcher.query)”.").font(.custom(HUDType.body.fontName, size: 13))
                    .foregroundStyle(HUD.inkMuted)
                HStack(spacing: HUD.space3) {
                    Button("Ask Aegis instead") { launcher.choose(ask: true) }.buttonStyle(HUDPlateStyle(kind: .primary, compact: true))
                    HUDKeyCaps(keys: ["⌘", "⏎"])
                }
            }
            .padding(HUD.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: HUD.space2) {
                    let rows = launcher.rows
                    ForEach(Array(launcher.groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.title).hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                                .padding(.horizontal, HUD.space4).padding(.vertical, 4)
                            ForEach(group.rows) { row in
                                let index = rows.firstIndex(of: row) ?? 0
                                LauncherRow(row: row, selected: index == launcher.selected) {
                                    launcher.selected = index
                                    launcher.choose()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, HUD.space2)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var foot: some View {
        HStack(spacing: HUD.space4) {
            hint(["↑", "↓"], "select")
            hint(["⏎"], "open")
            hint(["⌘", "⏎"], "ask Aegis")
            if let talk = ShellController.shared.talkKey {
                hint(ShellMenu.caps(talk), "speak")
            }
            Spacer()
        }
        .padding(.horizontal, HUD.space4)
        .padding(.vertical, 8)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 6) {
            HUDKeyCaps(keys: keys)
            Text(label).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
        }
    }
}

/// One result: its kind code, the title, where it lives, and ⏎ on the selected row.
private struct LauncherRow: View {
    let row: ShellLauncher.Row
    let selected: Bool
    let open: () -> Void
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: HUD.space3) {
                Text(row.kind.rawValue.uppercased()).font(HUDFace.mono(9)).tracking(0.7)
                    .foregroundStyle(row.kind == .ask ? HUD.accent : row.kind == .command ? HUD.ink : HUD.inkMuted)
                    .padding(.horizontal, 4)
                    .overlay(Rectangle().strokeBorder(
                        row.kind == .ask ? HUD.accent : row.kind == .command ? HUD.frame : HUD.line, lineWidth: 1
                    ))
                    .frame(width: 38, alignment: .leading)
                Text(row.title).font(.custom(HUDType.body.fontName, size: 13)).foregroundStyle(HUD.ink).lineLimit(1)
                Spacer(minLength: HUD.space2)
                if let meta = row.meta {
                    Text(meta).font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted).lineLimit(1).truncationMode(.head)
                }
                if selected {
                    HUDKeyCaps(keys: ["⏎"])
                }
            }
            .padding(.horizontal, HUD.space4)
            .frame(height: 34)
            .background {
                if selected {
                    LinearGradient(
                        stops: [.init(color: theme.color(.primarySoft), location: 0), .init(color: .clear, location: 0.8)],
                        startPoint: .leading, endPoint: .trailing
                    )
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(HUD.primary).frame(width: 2).hudGlow()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.kind.rawValue + ": " + row.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// jh-open: the bar opens from a line at its centre (420 ms on the standard curve); under Reduce Motion it just shows.
private struct LauncherArrival: ViewModifier {
    let opened: Date
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: still || Date().timeIntervalSince(opened) > 0.5)) { context in
            let progress = still ? 1 : HUDMotion.standard(min(max(context.date.timeIntervalSince(opened) / 0.42, 0), 1))
            content.scaleEffect(x: 1, y: max(progress, 0.02), anchor: .center).opacity(min(progress * 3, 1))
        }
    }
}

import AegisKit
import AppKit
import SwiftUI

/// The Settings window's pages (the design system's SettingsWindow), in its four groups. Only pages that hold settings
/// Aegis has today; the design's Workspaces, Memory, Shortcuts and About wait for their features. Brain isn't in the
/// design: it mirrors setup's Brain step and holds what the Claude and ChatGPT window did.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, brain, personality, voice, interface, silence, schedule
    case sources, permissions, privacy, storage
    case home, control, addons
    case mac, reset

    static let groups = ["Aegis", "What it reads", "What it does", "System"]

    var id: Self {
        self
    }

    var group: String {
        switch self {
        case .general, .brain, .personality, .voice, .interface, .silence, .schedule: "Aegis"
        case .sources, .permissions, .privacy, .storage: "What it reads"
        case .home, .control, .addons: "What it does"
        case .mac, .reset: "System"
        }
    }

    /// Its place on the rail, counted across the groups: the page's code (`05 / INTERFACE`).
    var number: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    var label: String {
        switch self {
        case .mac: "This Mac"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var title: String {
        self == .silence ? "Silence and alerts" : label
    }

    var intro: String {
        switch self {
        case .general: "How Aegis runs, and how it shows itself in the menu bar."
        case .brain: "What Aegis thinks with, and handing questions to Claude or ChatGPT."
        case .personality: "How Aegis talks to you. Tone only: it knows the same things in every style."
        case .voice: "How Aegis sounds while the panel is open, and when it listens."
        case .interface: "How Aegis looks, how the panel opens, and Aegis Mode."
        case .silence: "Aegis is silent while the panel is closed. Choose the few exceptions."
        case .schedule: "When your brief is ready, and when Aegis keeps still."
        case .sources: "What Aegis reads. Turn off anything it should ignore."
        case .permissions: "macOS keeps each kind of data behind its own permission."
        case .privacy: "What Aegis must never read. It reads everything else, and keeps all of it here."
        case .storage: "How much space Aegis may use. Models, memory, voice and addons all live inside it."
        case .home: "Your Apple Home, through the hubs you already have."
        case .control: "Which apps Aegis may operate, and how careful it is."
        case .addons: "Separate apps built to work with Aegis, and what each one may reach."
        case .mac: "What this Mac reported. It decides which models and voices fit."
        case .reset: "Start again, in part or in full."
        }
    }

    /// The words people use for what's on the page, for the find box.
    var keywords: String {
        switch self {
        case .general: "running laptop always on desktop menu bar icon exit status version setup"
        case .brain: "claude chatgpt openai anthropic model effort plan hand-off api key cloud reads"
        case .personality: "tone name preset formal humour warmth wake word calls sir notes"
        case .voice: "speak voice wake word speed warmth listen hey aegis preview"
        case .interface: "theme arc automaton phosphor redline matrix panel hotkey size position aegisshell aegis mode widgets appearance"
        case .silence: "glow urgent emergency vip alerts night quiet notifications"
        case .schedule: "brief morning wake time quiet hours focus"
        case .sources: "messages mail calendar whatsapp files browser clipboard screen photos accounts world view globe cesium keys weather flight"
        case .permissions: "full disk access accessibility contacts calendar reminders home macos"
        case .privacy: "never read exclude block apps people filevault"
        case .storage: "space gb disk drive band model keep messages"
        case .home: "lights garage lock thermostat devices homekit"
        case .control: "apps operate confirm send email messages"
        case .addons: "install performance monitor mail music calendar notes files"
        case .mac: "hardware chip memory laptop desktop macos apple intelligence"
        case .reset: "setup again start over"
        }
    }

    /// The find box: a label, title or keyword containing what's typed, ignoring case; everything when it's empty.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || [label, title, keywords].contains { $0.lowercased().contains(query) }
    }
}

/// The page on show, the find box, and the last change with its Undo (the design's footer: settings save as you make
/// them, there is no Apply).
@MainActor @Observable
final class SettingsModel {
    struct Change {
        let label: String
        let at: Date?
        let merge: String?
        let undo: (@MainActor () -> Void)?
    }

    var page = SettingsPane.general {
        didSet {
            // shortcut: Undo covers the page in view, since some pages keep a choice in their own state, which goes
            // with the page; keep each undo's state outside the page if Undo should reach across pages.
            if page != oldValue, let last {
                self.last = Change(label: last.label, at: last.at, merge: nil, undo: nil)
            }
        }
    }

    var query = ""
    private(set) var last: Change?

    /// The pages the find box matches, in rail order.
    var hits: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(query) }
    }

    /// A control changed something. A run of changes to one `merge` control (a slider's drag) keeps the first undo, so
    /// Undo goes back to before the run.
    func record(_ label: String, merge: String?, undo: (@MainActor () -> Void)?, at: Date = Date()) {
        let kept = merge != nil && last?.merge == merge ? last?.undo : undo
        last = Change(label: label, at: at, merge: merge, undo: kept)
    }

    /// One level of Undo.
    func undo() {
        guard let undo = last?.undo else { return }
        undo()
        last = Change(label: "Undone", at: nil, merge: nil, undo: nil)
    }

    /// Return in the find box: the first match.
    func openFirstHit() {
        if let first = hits.first {
            page = first
        }
    }
}

/// The window: 1360 × 860 like the wizard and the design, at the normal level so System Settings can come in front.
@MainActor
enum SettingsWindow {
    private(set) static var window: NSWindow?
    static let model = SettingsModel()

    /// Shows Settings (on `page`, if given); `runSetup` closes it and opens the wizard again.
    static func show(_ app: SetupApp, page: SettingsPane? = nil, setup: SetupModel = .shared, runSetup: @escaping () -> Void) {
        if let page {
            model.page = page
        }
        if window == nil {
            let created = HUDWindow(
                contentRect: NSRect(origin: .zero, size: SetupWindow.size), styleMask: [.borderless], backing: .buffered, defer: true
            )
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.isMovableByWindowBackground = true
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.contentView = NSHostingView(rootView: SettingsView(model: model, setup: setup, app: app, runSetup: {
                close()
                runSetup()
            }, close: close))
            created.center()
            window = created
        }
        setup.refreshFreeSpace()
        HUDPresence.shared.settings = true
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
        HUDPresence.shared.settings = false
    }
}

/// The design's SettingsShell: the brand bar and Aegis's state along the top; the find box over the grouped, numbered
/// rail on the left; the page's code, title, intro and content (fixed height, scrolling) on the right; the last change
/// with Undo, and Done, along the bottom.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var setup: SetupModel
    let app: SetupApp
    let runSetup: () -> Void
    let close: () -> Void
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @State private var missing = 0
    /// Sources AegisCore can read; nil while it hasn't answered.
    @State private var readable: Int?
    @FocusState private var finding: Bool

    var body: some View {
        let page = model.page
        HUDShell {
            SetupBrandBar(mode: "Settings")
            SettingsStatus(setup: setup, online: readable != nil)
        } content: {
            HStack(alignment: .top, spacing: HUD.space8) {
                SettingsRail(model: model, missing: missing, finding: $finding).frame(width: 224)
                VStack(alignment: .leading, spacing: 0) {
                    SetupHeading(
                        code: String(format: "%02d / ", page.number) + page.label.uppercased(),
                        title: page.title,
                        intro: page.intro
                    )
                    ScrollView(.vertical) {
                        SettingsPaneView(page: page, setup: setup, app: app, readable: readable, runSetup: runSetup)
                            .padding(.top, HUD.space6)
                            .padding(.trailing, HUD.space2)
                            .padding(.bottom, HUD.space4)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: 560)
                    .id(page)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(.timingCurve(0.05, 0.7, 0.1, 1, duration: 0.26), value: page)
        } bottom: {
            SettingsFooter(model: model, close: close)
        }
        .padding(HUD.space3)
        .frame(width: SetupWindow.size.width, height: SetupWindow.size.height)
        .background(HUDGround())
        .hudType(.body)
        .foregroundStyle(HUD.ink)
        .environment(\.colorScheme, .dark)
        .environment(\.hudTheme, theme)
        .environment(\.hudChange, HUDChange { label, merge, undo in model.record(label, merge: merge, undo: undo) })
        .background {
            // Escape clears the find box, then closes; ⌘W closes; ⌘F finds.
            Button("Close settings") {
                if model.query.isEmpty {
                    close()
                } else {
                    model.query = ""
                }
            }
            .keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            Button("Close settings", action: close).keyboardShortcut("w").opacity(0).accessibilityHidden(true)
            Button("Find a setting") { finding = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true)
        }
        // The wizard sends the brief time when it finishes; here each change goes at once.
        .onChange(of: setup.wizard.briefMinutes) { _, minutes in
            Task { _ = await app.model.service.handle(.setBriefTime(minutes: minutes)) }
        }
        // Permissions are checked again on each page change and whenever the window comes back to the front.
        .task(id: page) { missing = Permission.missing(Self.granted()) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            missing = Permission.missing(Self.granted())
        }
        .task {
            if case let .status(status) = await app.model.service.handle(.status) {
                readable = status.sources.filter(\.readable).count
            }
        }
    }

    private static func granted() -> [Permission: Bool] {
        Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.granted) })
    }
}

/// Top right: whether AegisCore answers, and the brain, band and storage in mono.
private struct SettingsStatus: View {
    @Bindable var setup: SetupModel
    let online: Bool
    @Bindable private var brain = BrainSettings.shared

    var body: some View {
        let mind = brain.brain == .claude ? "Claude" : SetupText.parameters(.current) + "B · " + SetupText.band(setup.wizard).title
        HStack(spacing: HUD.space4) {
            HUDTag(word: online ? "Online" : "Core offline", tone: online ? HUD.primary : HUD.warn)
            Text(mind + " · \(setup.wizard.storageGB) GB").font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The find box over the pages in their groups: each numbered, the current one lit, Permissions with a warn badge
/// while any are missing.
private struct SettingsRail: View {
    @Bindable var model: SettingsModel
    let missing: Int
    var finding: FocusState<Bool>.Binding
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: HUD.space4) {
            HStack(spacing: HUD.space2) {
                Text("find >").foregroundStyle(HUD.primary).fixedSize()
                TextField("", text: $model.query, prompt: Text("a setting").foregroundStyle(HUD.inkMuted))
                    .textFieldStyle(.plain)
                    .foregroundStyle(HUD.ink)
                    .focused(finding)
                    .onSubmit { model.openFirstHit() }
                    .accessibilityLabel("Find a setting")
                if searching {
                    Text("\(model.hits.count)").foregroundStyle(HUD.primary).frame(minWidth: 18).padding(.horizontal, 4)
                        .background(HUD.primarySoft)
                } else {
                    HUDKeyCaps(keys: ["⌘", "F"]).opacity(0.8)
                }
            }
            .font(HUDFace.mono(11))
            .hudField(focused: finding.wrappedValue)
            ForEach(SettingsPane.groups, id: \.self) { group in
                let pages = SettingsPane.allCases.filter { $0.group == group && $0.matches(model.query) }
                if !pages.isEmpty {
                    VStack(alignment: .leading, spacing: HUD.space1) {
                        Text(group).hudCaps(9, tracking: 0.24).foregroundStyle(HUD.primary).padding(.leading, HUD.space3)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(pages) { item($0) }
                        }
                        .overlay(alignment: .leading) { Rectangle().fill(HUD.glassEdge).frame(width: 1) }
                    }
                }
            }
            if searching, model.hits.isEmpty {
                SetupNote("nothing matches \u{201C}\(model.query)\u{201D}").padding(.leading, HUD.space3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func item(_ page: SettingsPane) -> some View {
        let current = page == model.page
        return Button { model.page = page } label: {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                Text(String(format: "%02d", page.number)).font(HUDFace.mono(10)).foregroundStyle(current ? HUD.primary : HUD.inkMuted)
                Text(page.label).hudCaps(10, tracking: 0.14).foregroundStyle(HUD.ink).frame(maxWidth: .infinity, alignment: .leading)
                if page == .permissions, missing > 0 {
                    Text("\(missing)").font(HUDFace.mono(9)).foregroundStyle(HUD.warn).frame(minWidth: 14).padding(.horizontal, 4)
                        .overlay(Rectangle().strokeBorder(HUD.warn, lineWidth: 1))
                        .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
                        .accessibilityLabel("\(missing) needed")
                }
            }
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, HUD.space3)
            .background {
                if current {
                    LinearGradient(colors: [theme.color(.primarySoft), .clear], startPoint: .leading, endPoint: .trailing)
                }
            }
            .overlay(alignment: .leading) {
                if current {
                    Rectangle().fill(HUD.primary).frame(width: 2).hudGlow().offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupRailStyle())
        .disabled(current)
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }
}

/// What just changed, with Undo, or that changes save as you make them; ⌘W and Done on the right.
private struct SettingsFooter: View {
    @Bindable var model: SettingsModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: HUD.space6) {
            HStack(spacing: HUD.space3) {
                Rectangle().fill(model.last == nil ? HUD.inkMuted : HUD.ok).frame(width: 6, height: 6)
                    .hudGlow(.ok, active: model.last != nil)
                if let last = model.last {
                    Text("Saved: ") + Text(last.label).foregroundStyle(HUD.ink)
                    if let at = last.at {
                        Text(at.formatted(date: .omitted, time: .shortened))
                    }
                    if last.undo != nil {
                        Button("Undo") { model.undo() }.buttonStyle(HUDPlateStyle(compact: true))
                    }
                } else {
                    Text("Changes save as you make them")
                }
            }
            .font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            HStack(spacing: HUD.space3) {
                HUDKeyCaps(keys: ["⌘", "W"])
                Button("Done", action: close).buttonStyle(HUDPlateStyle(kind: .primary))
            }
        }
        .frame(minHeight: 30)
    }
}

/// Each page: the wizard's own screen where Settings shows the same step, so both read and write one copy of each
/// answer; General, Interface and Reset are laid out as the design's Settings pages have them.
private struct SettingsPaneView: View {
    let page: SettingsPane
    @Bindable var setup: SetupModel
    let app: SetupApp
    let readable: Int?
    let runSetup: () -> Void

    var body: some View {
        switch page {
        case .general: SettingsGeneral(setup: setup, app: app, readable: readable, runSetup: runSetup)
        case .brain: BrainScreen(handOff: true)
        case .personality: PersonalityScreen(setup: setup, model: app.model)
        case .voice: VoiceScreen(setup: setup, app: app)
        case .interface: SettingsInterface(setup: setup, app: app)
        case .silence: SilenceScreen(setup: setup, model: app.model)
        case .schedule: ScheduleScreen(setup: setup, inSettings: true)
        case .sources: SourcesScreen(setup: setup, model: app.model, inSettings: true)
        case .permissions: PermissionsScreen(inSettings: true)
        case .privacy: PrivacyScreen(setup: setup)
        case .storage: StorageScreen(setup: setup)
        case .home: HomeScreenStep(setup: setup)
        case .control: ControlScreen(setup: setup)
        case .addons: AddonsScreen(setup: setup)
        case .mac: MacScreen(setup: setup)
        case .reset: SettingsReset(runSetup: runSetup)
        }
    }
}

// MARK: - 01 General

/// How Aegis runs and its menu bar item, beside the core and what Aegis is doing now.
private struct SettingsGeneral: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    let readable: Int?
    let runSetup: () -> Void
    @Bindable private var brain = BrainSettings.shared

    var body: some View {
        SetupColumns {
            HUDSubhead(title: "Running", first: true)
            SetupRunningRow(setup: setup)
            HUDSubhead(title: "Menu bar item", meta: "beside Control Centre")
            HUDSettingRow(label: "Icon") {
                HUDSegmented(label: "Menu bar icon", options: [
                    HUDOption(value: "reactor", label: "Reactor"), HUDOption(value: "hex", label: "Hex"), HUDOption(
                        value: "mono",
                        label: "Mono"
                    ),
                ], value: setup.option("menuIcon", "reactor"), small: true)
            }
            HUDSettingRow(
                label: "Exit",
                hint: "Always in AegisShell's bar while it's engaged, so you can leave even if something misbehaves."
            ) {
                HUDTag(word: "Always shown", tone: HUD.ok)
            }
        } side: {
            SetupCentre { HUDReactorCore(
                mode: .idle,
                size: 200,
                label: app.model.personality.name,
                value: readable == nil ? "----" : "Online"
            ) }
            HUDTermSection(title: "Aegis", rows: [
                .init(
                    label: "Status",
                    value: readable.map { "Online · reading \($0) sources" } ?? "AegisCore isn't answering",
                    tone: readable == nil ? .warn : .ok
                ),
                .init(
                    label: "Brain",
                    value: brain.brain == .claude ? "Claude · your plan" : SetupText.model(.current) + " · " + SetupText.band(setup.wizard)
                        .title
                ),
                .init(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "----"),
            ])
            Spacer().frame(height: HUD.space3)
            HUDSettingRow(label: "Setup", hint: "Every step again, with your current answers filled in.") {
                Button("Run setup again", action: runSetup).buttonStyle(HUDPlateStyle(compact: true)).fixedSize()
            }
        }
    }
}

// MARK: - 05 Interface

/// The theme (this window follows it) and the panel on the left; Aegis Mode and desktop widgets on the right.
private struct SettingsInterface: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @Environment(\.hudChange) private var change

    var body: some View {
        SetupColumns(kind: .halves) {
            HUDSubhead(title: "Theme", meta: "this window follows", first: true)
            HStack(spacing: HUD.space2) {
                ForEach(HUDTheme.allCases, id: \.self) { choice in
                    ThemeSwatch(theme: choice, chosen: theme == choice) { pick(choice) }
                }
            }
            .padding(.vertical, HUD.space2)
            HUDSubhead(title: "The panel")
            HUDSettingRow(
                label: "Open with",
                hint: app.hotKey == nil ? "Every Aegis shortcut is taken by another app: open Aegis from its menu bar icon." : nil
            ) {
                HUDKeyCaps(keys: SetupText.keys(app.hotKey ?? "----"))
            }
            HUDSettingRow(label: "Size") {
                HUDSegmented(label: "Panel size", options: [
                    HUDOption(value: "full", label: "Full screen"), HUDOption(value: "large", label: "Large"),
                    HUDOption(value: "compact", label: "Compact"),
                ], value: setup.option("panelSize", "full"), small: true)
            }
            HUDSettingRow(label: "Position") {
                HUDSegmented(
                    label: "Panel position",
                    options: [HUDOption(value: "centre", label: "Centre"), HUDOption(value: "top", label: "Top")],
                    value: setup.option("panelPosition", "centre"),
                    small: true
                )
            }
        } side: {
            HUDSubhead(title: "Aegis Mode", meta: "AegisShell over macOS, on demand", first: true)
            HUDSettingRow(
                label: "Engage with",
                hint: app.shellKey == nil ? "Another app holds the shortcut: engage from the menu bar." : nil
            ) {
                HUDKeyCaps(keys: SetupText.keys(app.shellKey ?? "----"))
            }
            HUDSettingRow(label: "Voice phrase", hint: app.wake.enabled ? nil : "Needs the wake word (Voice).", dim: !app.wake.enabled) {
                Text("\"\(app.model.personality.name), engage\"").font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
            }
            HUDSettingRow(label: "Engage automatically", hint: "On a Mac mini hub, or when a workspace starts.") {
                HUDToggle(on: setup.flag("shellAuto", false), label: "Engage automatically")
            }
            HUDSettingRow(label: "Desktop widgets", hint: "Status, waiting on you, next up, home. Native widgets, almost no cost.") {
                HUDToggle(on: setup.flag("widgets", true), label: "Desktop widgets")
            }
        }
    }

    private func pick(_ choice: HUDTheme) {
        let old = theme
        guard choice != old else { return }
        theme = choice
        change?.record("Theme: " + choice.title, nil) { UserDefaults.aegis.set(old.rawValue, forKey: HUDTheme.storeKey) }
    }
}

// MARK: - 16 Reset

/// Running setup again, the one way to start over that Aegis has today.
private struct SettingsReset: View {
    let runSetup: () -> Void

    var body: some View {
        SetupColumns {
            HUDSettingRow(label: "Run setup again", hint: "Every step, with your current answers filled in. Nothing is lost.") {
                Button("Run setup", action: runSetup).buttonStyle(HUDPlateStyle(compact: true))
            }
            SetupNote("Aegis never deletes your own files, here or anywhere.").padding(.top, HUD.space3)
        } side: {
            SetupCentre { HUDAsciiArt(shape: .orb, cols: 34, rows: 15, tone: HUD.accent, label: "Start again") }
        }
    }
}

// MARK: - Keys

/// A key or token kept in the Keychain: its name, where to get it, a hidden field, and Save (or Remove once saved and
/// the field is empty). A saved key never shows again.
struct SetupKeyRow: View {
    let name: String
    var use: String?
    let site: String
    let isSaved: () -> Bool
    /// False when the Keychain refused.
    let save: (String) -> Bool
    let remove: () -> Void
    @State private var text = ""
    @State private var saved = false
    @State private var refused = false
    @Environment(\.hudChange) private var change

    var body: some View {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        HUDSettingRow(label: name, hint: refused ? "The Keychain didn't save that key." : "Free from " + site, meta: use) {
            HUDTermInput(prompt: ">", text: $text, placeholder: saved ? "saved" : "paste it here", secure: true).frame(width: 130)
            Button(typed.isEmpty && saved ? "Remove" : "Save") {
                if typed.isEmpty {
                    remove()
                    change?.record(name + " removed", nil, nil)
                } else {
                    refused = !save(typed)
                    if !refused {
                        change?.record(name + " saved", nil, nil)
                    }
                }
                text = ""
                saved = isSaved()
            }
            .buttonStyle(HUDPlateStyle(compact: true))
            .fixedSize()
            .disabled(typed.isEmpty && !saved)
        }
        .onAppear { saved = isSaved() }
    }
}

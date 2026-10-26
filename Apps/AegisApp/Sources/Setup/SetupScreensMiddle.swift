import AegisKit
import AppKit
import SwiftUI

// MARK: - 06 Sources

/// What Aegis reads: the sources AegisCore reports, with what it found in each, then this Mac's own sources. A switch
/// keeps its answer for when sources can be turned off one by one (#65); sensitive ones start off.
struct SourcesScreen: View {
    @Bindable var setup: SetupModel
    let model: PanelModel
    @State private var coverage: [SourceKind: SourceCoverage] = [:]

    var body: some View {
        let accounts = Self.accounts.map { row in (row, setup.flag("source." + row.key, true)) }
        let mac = Self.macSources.map { row in (row, setup.flag("source." + row.key, row.on)) }
        SetupColumns(kind: .halves) {
            HUDSubhead(title: "Accounts and apps", meta: "\(accounts.filter(\.1.wrappedValue).count) on", first: true)
            ForEach(accounts, id: \.0.key) { row, on in
                HUDSettingRow(label: row.name, meta: meta(row), compact: true) {
                    HUDToggle(on: on, label: row.name, showState: false)
                }
            }
            HUDSubhead(title: "Suggested", meta: "so nothing is missed")
            HUDSettingRow(label: "Another email", meta: "add to Apple Mail", compact: true) {
                Button("Show me") { SetupLink.openMail() }.buttonStyle(HUDPlateStyle(compact: true))
            }
            HUDSettingRow(label: "Instagram", meta: "turn on web notifications", compact: true) {
                Button("Show me") { SetupLink.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                    .buttonStyle(HUDPlateStyle(compact: true))
            }
            HUDSettingRow(label: "Messenger", meta: "install the Mac app", compact: true) {
                Button("Show me") { SetupLink.open("macappstores://apps.apple.com/app/id1480068668") }
                    .buttonStyle(HUDPlateStyle(compact: true))
            }
        } side: {
            HUDSubhead(title: "This Mac", meta: "\(mac.filter(\.1.wrappedValue).count) of \(mac.count) on", first: true)
            ForEach(mac, id: \.0.key) { row, on in
                HUDSettingRow(label: row.name, meta: row.meta, compact: true) {
                    HUDToggle(on: on, label: row.name, showState: false)
                }
            }
            HUDSubhead(title: "World view", meta: "live public data")
            HUDSettingRow(label: "Globe", meta: "free Cesium key: 3D cities", compact: true) {
                Button("Add key") { WorldKeysWindow.show() }.buttonStyle(HUDPlateStyle(compact: true))
                HUDToggle(on: setup.flag("world", true), label: "World view", showState: false)
            }
        }
        .task {
            if case let .status(status) = await model.service.handle(.status) {
                coverage = Dictionary(status.sources.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
    }

    /// What AegisCore found in the row's sources, or how it reaches them.
    private func meta(_ row: Row) -> String {
        let found = row.kinds.compactMap { coverage[$0] }
        guard !found.isEmpty else { return row.meta }
        if let blocked = found.first(where: { !$0.readable }) {
            return BriefPresentation.state(blocked)
        }
        return "\(found.map(\.events).reduce(0, +).formatted()) items"
    }

    struct Row {
        let key: String
        let name: String
        let meta: String
        var kinds: [SourceKind] = []
        var on = true
    }

    private static let accounts = [
        Row(key: "messages", name: "Messages and SMS", meta: "iMessage and SMS", kinds: [.messages]),
        Row(key: "mail", name: "Mail", meta: "accounts in Apple Mail", kinds: [.mail]),
        Row(key: "calendar", name: "Calendar and Reminders", meta: "calendars and lists", kinds: [.calendar, .reminders]),
        Row(key: "contacts", name: "Contacts", meta: "names for senders", kinds: [.contacts]),
        Row(key: "whatsapp", name: "WhatsApp", meta: "through its Mac notifications"),
        Row(key: "notifications", name: "Mac notifications", meta: "every app · catch-all", kinds: [.notifications]),
        Row(key: "context", name: "Mac context", meta: "Focus, battery, Wi-Fi"),
    ]

    private static let macSources = [
        Row(key: "files", name: "Files and folders", meta: "Spotlight index; read on demand"),
        Row(key: "notes", name: "Notes", meta: "Searchable notes"),
        Row(key: "browser", name: "Browser history and tabs", meta: "Safari and Chrome"),
        Row(key: "downloads", name: "Downloads and recent", meta: "Newly arrived files"),
        Row(key: "photos", name: "Photos", meta: "Search by date, place, people", on: false),
        Row(key: "front", name: "Front app and windows", meta: "\"What am I working on\""),
        Row(key: "code", name: "Terminal, Xcode and git", meta: "Folders you pick", on: false),
        Row(key: "clipboard", name: "Clipboard", meta: "Recent copied items", on: false),
        Row(key: "screen", name: "Screen context", meta: "On-device; indicator while on", on: false),
    ]
}

// MARK: - 07 Home

/// Home control and how careful it is per kind of device. Aegis doesn't reach Apple Home yet (HomeHelper, Stage 5),
/// so what it would find shows as `----` rather than invented rooms; locks and the garage are fixed to Confirm.
struct HomeScreenStep: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let on = setup.flag("home", true)
        SetupColumns {
            HUDSettingRow(label: "Home control", hint: "Control the Home app’s devices from the panel, by text or voice.") {
                HUDToggle(on: on, label: "Home control")
            }
            HStack(spacing: HUD.space8) {
                ForEach(["Home", "Rooms", "Devices", "Scenes"], id: \.self) { label in
                    HUDReadout(label: label, value: "----", tone: label == "Devices" ? HUD.primary : HUD.ink)
                }
            }
            .padding(.top, HUD.space3)
            HUDSubhead(title: "When you ask", meta: "what happens")
            ForEach(Self.devices, id: \.0) { key, name, secure in
                HUDSettingRow(label: name, meta: secure ? "security" : nil, compact: true, dim: !on.wrappedValue) {
                    HUDSegmented(label: name, options: [
                        HUDOption(value: "instant", label: "Instant", disabled: secure), HUDOption(value: "confirm", label: "Confirm"),
                    ], value: secure ? .constant("confirm") : setup.option("device." + key, "instant"), small: true, locked: secure)
                }
            }
            SetupNote("Locks and the garage always ask first. Aegis never changes a security device unless you tell it to.")
                .padding(.top, HUD.space2)
        } side: {
            SetupCentre {
                HUDAsciiArt(
                    shape: .radar,
                    cols: 34,
                    rows: 17,
                    tone: on.wrappedValue ? HUD.primary : HUD.ink,
                    label: "Home devices found",
                    animate: on.wrappedValue
                )
                HUDTermSection(title: "Rooms", rows: [.init(label: "----", value: "found once Home is connected")])
            }
        }
    }

    private static let devices = [
        ("lights", "Lights", false), ("plugs", "Plugs", false), ("thermostat", "Thermostat", false), ("blinds", "Blinds", false),
        ("garage", "Garage door", true), ("lock", "Front door lock", true),
    ]
}

// MARK: - 08 Control

/// Which apps Aegis may operate, the confirmation tiers the action safety system applies (ADR-0016), and whether
/// messages are only prepared or sent when the owner says.
struct ControlScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let apps = Self.apps.map { app in (app, setup.flag("app." + app.0, app.2)) }
        VStack(alignment: .leading, spacing: 0) {
            HUDSubhead(
                title: "Apps Aegis may control",
                meta: "\(apps.filter(\.1.wrappedValue).count) of \(apps.count) · macOS asks once per app",
                first: true
            )
            HStack(alignment: .top, spacing: HUD.space6) {
                ForEach(0 ..< 3, id: \.self) { column in
                    VStack(spacing: 0) {
                        ForEach(apps[column * 4 ..< column * 4 + 4], id: \.0.0) { app, on in
                            HUDSettingRow(label: app.0, meta: app.1, compact: true) { HUDToggle(on: on, label: app.0, showState: false) }
                        }
                    }
                }
            }
            HUDSubhead(title: "Confirmation", meta: "safe defaults")
            HStack(alignment: .top, spacing: 0) {
                tier("Instant", tag: "Go", tone: HUD.ok, items: ["Opening apps and files", "Music, lights, scenes", "Notes and reminders"])
                tier(
                    "Confirm first",
                    tag: "Ask",
                    tone: HUD.warn,
                    items: ["Sending messages and email", "Invites to other people", "Locks and the garage", "Moving or editing files"]
                )
                tier(
                    "Never",
                    tag: "You do it",
                    tone: HUD.critical,
                    items: ["Payments and purchases", "Deleting data", "Changing passwords"]
                )
                .background(HUDHatch(gap: 7).fill(HUD.critical).opacity(0.18))
            }
            .overlay(Rectangle().strokeBorder(HUD.glassEdge, lineWidth: 1))
            let send = setup.option("send", "prepare")
            HUDSettingRow(
                label: "Messages and email",
                hint: send.wrappedValue == "prepare" ? "Aegis writes and addresses them; you press Send."
                    : "Say \"…and send it\": Aegis sends after you confirm twice."
            ) {
                HUDSegmented(label: "Messages and email", options: [
                    HUDOption(value: "prepare", label: "Prepare for me"), HUDOption(value: "send", label: "Send when I say"),
                ], value: send)
            }
        }
    }

    private func tier(_ title: String, tag: String, tone: HUDColor, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            HStack {
                Text(title).hudCaps(10, tracking: 0.18).foregroundStyle(HUD.ink)
                Spacer()
                HUDTag(word: tag, tone: tone)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.self) { item in
                    (Text("─ ").font(HUDFace.mono(11)).foregroundStyle(HUD.line) + Text(item).foregroundStyle(HUD.inkMuted))
                        .font(HUDFace.text(11)).frame(height: 18)
                }
            }
        }
        .padding(HUD.space3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            if title != "Instant" {
                Rectangle().fill(HUD.glassEdge).frame(width: 1)
            }
        }
    }

    private static let apps = [
        ("Calendar", "Framework", true), ("Reminders", "Framework", true), ("Contacts", "Framework", true), ("Music", "Framework", true),
        ("Mail", "AppleScript", true), ("Messages", "AppleScript", true), ("Notes", "AppleScript", true), ("Safari", "AppleScript", true),
        ("Finder", "AppleScript", true), ("Photos", "AppleScript", false), ("Keynote", "AppleScript", false), (
            "Shortcuts",
            "Shortcuts",
            true
        ),
    ]
}

// MARK: - 09 Addons

/// The addons to download once the addon library ships: ticked ones are kept with the answers, and their share of
/// the storage shows below.
struct AddonsScreen: View {
    @Bindable var setup: SetupModel

    var body: some View {
        let chosen = SetupText.addons.filter { setup.flag("addon." + $0.key, $0.key == "perf").wrappedValue }
        let gigabytes = chosen.map(\.gigabytes).reduce(0, +)
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: HUD.space3), GridItem(.flexible())], spacing: HUD.space3) {
                ForEach(Array(SetupText.addons.enumerated()), id: \.offset) { index, addon in
                    let on = setup.flag("addon." + addon.key, addon.key == "perf")
                    HUDChoiceCard(
                        title: addon.name, description: addon.about, selected: on.wrappedValue, multiple: true,
                        badge: addon.key == "perf" ? "Suggested" : nil, meta: "\(Int(addon.gigabytes * 1000)) MB",
                        extra: "Reads \(addon.reads) · " + (addon.can == "only read" ? "Read only" : "Can \(addon.can)"),
                        action: { on.wrappedValue.toggle() }
                    ) {
                        HUDAsciiArt(
                            shape: addon.shape,
                            cols: 10,
                            rows: 5,
                            detail: 3,
                            grit: 0.08,
                            seed: Double(index + 3),
                            animate: on.wrappedValue
                        )
                    }
                }
            }
            Spacer().frame(height: HUD.space3)
            HUDMeter(
                label: "Of your \(setup.wizard.storageGB) GB",
                value: max(gigabytes > 0 ? 0.01 : 0, gigabytes / Double(setup.wizard.storageGB)),
                display: String(format: "%.2f GB · %d %@", gigabytes, chosen.count, chosen.count == 1 ? "addon" : "addons"),
                size: .medium,
                tone: HUD.accent,
                segments: 60
            )
            SetupNote("Each addon is signed and checked before it runs. You approve what it can do once, here. Add or remove them "
                + "any time in 06 Addons.")
                .padding(.top, HUD.space2)
        }
    }
}

// MARK: - 10 Privacy

/// What Aegis must never read, kept with the answers, and the FileVault check.
struct PrivacyScreen: View {
    @Bindable var setup: SetupModel
    @State private var fileVault: Bool?
    @State private var adding = false
    @State private var person = ""

    var body: some View {
        let apps = setup.list("neverApps", ["1Password", "Banking apps"])
        let people = setup.list("neverPeople", [])
        SetupColumns {
            HUDSubhead(title: "Never read these apps", meta: "\(apps.wrappedValue.count) excluded", first: true)
            SetupChips(items: apps, empty: "None.")
            Button("Add app") { addApp(to: apps) }.buttonStyle(HUDPlateStyle(compact: true))
            HUDSubhead(
                title: "Never read these chats or people",
                meta: people.wrappedValue.isEmpty ? nil : "\(people.wrappedValue.count) excluded"
            )
            SetupChips(items: people, empty: "None yet. Aegis won’t read or remember anything from a chat or person you add here.")
            if adding {
                HUDTermInput(prompt: "who >", text: $person, placeholder: "a name or group chat", hint: "return to add", autofocus: true) {
                    setup.typing = $0
                }
                .onSubmit {
                    let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, !people.wrappedValue.contains(name) {
                        people.wrappedValue.append(name)
                    }
                    person = ""
                    adding = false
                }
            } else {
                Button("Add chat or person") { adding = true }.buttonStyle(HUDPlateStyle(compact: true))
            }
            HUDSubhead(title: "This Mac")
            HUDSettingRow(
                label: "FileVault",
                hint: fileVault == false ? "Off: turn it on so everything Aegis keeps is encrypted too."
                    : "Your disk is encrypted, so everything Aegis keeps is too."
            ) {
                if fileVault == false {
                    Button("Turn on") { SetupLink.open("x-apple.systempreferences:com.apple.preference.security?FileVault") }
                        .buttonStyle(HUDPlateStyle(compact: true))
                }
                HUDTag(word: fileVault.map { $0 ? "On" : "Off" } ?? "Checking", tone: fileVault == false ? HUD.warn : HUD.ok)
            }
        } side: {
            SetupCentre { HUDEmblemArt(cols: 40, label: "The Aegis shield") }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rules, id: \.0) { title, text in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).hudCaps(10, tracking: 0.16).foregroundStyle(HUD.ink)
                        Text(text).font(HUDFace.text(11)).foregroundStyle(HUD.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, HUD.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
                }
            }
        }
        .task { fileVault = await SetupLink.fileVaultOn() }
    }

    /// Picks an app from Applications and adds its name.
    private func addApp(to apps: Binding<[String]>) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        if !apps.wrappedValue.contains(name) {
            apps.wrappedValue.append(name)
        }
    }

    private static let rules = [
        ("Stays here", "Everything Aegis collects and learns stays on this Mac."),
        ("Data, not orders", "A message can never tell Aegis what to do. Only you can."),
        ("Forget anything", "Ask Aegis to forget a fact, or a whole person, any time."),
    ]
}

/// Removable chips, or a note when there are none.
struct SetupChips: View {
    @Binding var items: [String]
    let empty: String
    var removable = true
    var dim = false

    var body: some View {
        if items.isEmpty {
            SetupNote(empty).padding(.vertical, HUD.space2)
        } else {
            SetupFlow(spacing: HUD.space2) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: HUD.space2) {
                        Text(item).foregroundStyle(HUD.ink)
                        if removable {
                            Button("×") { items.removeAll { $0 == item } }.buttonStyle(.plain).foregroundStyle(HUD.inkMuted)
                                .accessibilityLabel("Remove \(item)")
                        }
                    }
                    .font(HUDFace.mono(11))
                    .padding(.horizontal, HUD.space2)
                    .frame(height: 24)
                    .background(HUD.surface)
                    .overlay(Rectangle().strokeBorder(HUD.frame, lineWidth: 1))
                }
            }
            .padding(.vertical, HUD.space2)
            .opacity(dim ? 0.5 : 1)
        }
    }
}

/// Lays its children out left to right, wrapping onto new rows.
struct SetupFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.top + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var left = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: left, y: bounds.minY + row.top), proposal: ProposedViewSize(size))
                left += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var top: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, !last.items.isEmpty, last.width + spacing + size.width > width {
                rows.append(Row(top: last.top + last.height + spacing))
            }
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += (rows[rows.count - 1].items.count > 1 ? spacing : 0) + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

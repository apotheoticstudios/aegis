import AegisKit
import AppKit
import SwiftUI

/// The wizard's preference screens (#28). Each shows only what Aegis can already do and writes the same setting its
/// menu or settings window does; the options DESIGN.md lists for features not built yet join as they're built.
struct SourcesScreen: View {
    let model: PanelModel
    @State private var sources: [SourceCoverage] = []
    @State private var worldLine = WorldPresence.briefEnabled

    var body: some View {
        HUDSection(title: "What Aegis reads", code: "ON THIS MAC", first: true, linked: false) {
            if sources.isEmpty {
                SetupLine("Messages, Mail and notifications once Full Disk Access is on; Calendar and Reminders with their own access.")
            }
            ForEach(sources, id: \.source) { coverage in
                HStack {
                    Text(BriefPresentation.name(coverage.source)).hudType(.label)
                    Spacer()
                    HUDTag(word: BriefPresentation.state(coverage), tone: coverage.readable ? HUD.ok : HUD.warn)
                }
            }
        }
        HUDSection(title: "Other apps", linked: false) {
            SetupLine(
                "WhatsApp, Messenger, Telegram, Slack and Discord reach Aegis through their Mac notifications: use their Mac "
                    + "apps, or allow notifications from their websites, and keep those notifications on."
            )
            SetupLine("Email comes through Apple Mail: add your accounts there. Aegis keeps Mail running, hidden.")
            HStack(spacing: HUD.space2) {
                Button("Notification settings") { SetupLink.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                Button("Open Mail") { SetupLink.openMail() }
            }
            .buttonStyle(HUDChipStyle())
        }
        HUDSection(title: "World view", linked: false) {
            SetupSwitch(title: "Weather at home and today's flights in the brief", isOn: $worldLine)
            SetupLine("The globe of public data opens from the panel. 3D cities need a free Cesium ion key.", muted: true)
            Button("World view keys…") { WorldKeysWindow.show() }.buttonStyle(HUDChipStyle())
        }
        .onChange(of: worldLine) { _, on in WorldPresence.briefEnabled = on }
        .task {
            if case let .status(status) = await model.service.handle(.status) {
                sources = status.sources
            }
        }
    }
}

struct PrivacyScreen: View {
    @State private var fileVault: Bool?

    var body: some View {
        HUDSection(title: "Private by design", first: true, linked: false) {
            SetupLine("What Aegis collects, and the AI that reads it, stay on this Mac.")
            SetupLine("Collected messages and mail are only ever information: nothing in them can make Aegis act. Only you can.")
        }
        HUDSection(title: "FileVault", linked: false) {
            HStack {
                SetupLine(fileVault == false
                    ? "Off: turn it on so everything on this Mac, Aegis's data included, is encrypted."
                    : "Everything on this Mac, Aegis's data included, is encrypted while FileVault is on.")
                Spacer()
                HUDTag(word: fileVault.map { $0 ? "On" : "Off" } ?? "Checking", tone: fileVault == false ? HUD.warn : HUD.ok)
                if fileVault == false {
                    Button("Turn on") { SetupLink.open("x-apple.systempreferences:com.apple.preference.security?FileVault") }
                        .buttonStyle(HUDChipStyle())
                }
            }
        }
        HUDSection(title: "Claude and ChatGPT", linked: false) {
            let providers = CloudKeys.availability.providers
            SetupLine(providers.isEmpty
                ? "Off. You can let Aegis hand deeper questions to Claude or ChatGPT; only your own words go, never your data."
                : "On for \(providers.map(\.name).joined(separator: " and ")): only your own words, for questions with "
                + "nothing personal in them, never your messages, mail, calendar, contacts or memory.")
            Button("Claude and ChatGPT…") { CloudSettingsWindow.show() }.buttonStyle(HUDChipStyle())
        }
        .task { fileVault = await SetupLink.fileVaultOn() }
    }
}

struct PersonalityScreen: View {
    let model: PanelModel
    @State private var chosen = Personality.standard
    @State private var loaded = false
    @FocusState private var field: Field?

    private enum Field {
        case name, call, notes
    }

    var body: some View {
        HUDSection(title: "Personality", first: true, linked: false) {
            HStack(spacing: HUD.space2) {
                ForEach(Personality.Style.allCases, id: \.self) { style in
                    SetupChoice(title: style.title, chosen: chosen.style == style) { chosen.style = style }
                }
            }
            SetupLine(chosen.style.description.prefix(1).uppercased() + chosen.style.description.dropFirst(), muted: true)
        }
        HUDSection(title: "Name", linked: false) {
            entry("Aegis", text: $chosen.name, .name)
            SetupLine("A one-word name also works as the wake word; “Hey Aegis” always does.", muted: true)
        }
        HUDSection(title: "Call me", linked: false) {
            entry("sir, boss, your name, or leave it empty", text: $chosen.callOwner, .call)
        }
        HUDSection(title: "Anything else", linked: false) {
            entry("swear a bit, roast me, keep it really short…", text: $chosen.notes, .notes)
            if chosen.cleaned == nil {
                SetupLine("The name needs letters only, up to 24; notes up to 600 characters.", tone: HUD.warn)
            }
        }
        .task {
            await model.loadPersonality()
            chosen = model.personality
            loaded = true
        }
        // Saved through AegisCore a moment after the owner stops typing.
        .task(id: chosen) {
            try? await Task.sleep(for: .milliseconds(600))
            guard loaded, !Task.isCancelled, let clean = chosen.cleaned, clean != model.personality else { return }
            _ = await model.savePersonality(clean)
        }
    }

    private func entry(_ prompt: String, text: Binding<String>, _ which: Field) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(HUD.inkMuted)).textFieldStyle(.plain).hudType(.term).focused(
            $field,
            equals: which
        )
        .hudField(focused: field == which)
    }
}

struct VoiceScreen: View {
    let setup: SetupModel
    let model: PanelModel
    let wake: WakeListener
    @State private var listening = false

    var body: some View {
        let name = model.personality.name
        HUDSection(title: "Hey \(name)", first: true, linked: false) {
            SetupSwitch(title: "Listen for “Hey \(name)”", isOn: Binding(get: { listening }, set: { on in
                listening = on
                Task { await wake.set(enabled: on) }
            }))
            SetupLine("Only the wake word is listened for, on this Mac; nothing is recorded or sent anywhere.", muted: true)
            if let problem = wake.problem {
                SetupLine(problem, tone: HUD.warn)
            }
        }
        HUDSection(title: "Voice", linked: false) {
            Button("Hear \(name)") {
                model.voice.speak("I'm \(name). Your brief will be ready by \(SetupText.time(setup.wizard.briefMinutes)).")
            }
            .buttonStyle(HUDChipStyle())
            SetupLine("Questions you ask aloud are answered aloud, only while the panel is open.", muted: true)
        }
        .onAppear { listening = wake.enabled }
    }
}

struct InterfaceScreen: View {
    let hotKey: String?
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        HUDSection(title: "Theme", first: true, linked: false) {
            HStack(spacing: HUD.space2) {
                ForEach(HUDTheme.allCases, id: \.self) { choice in
                    SetupChoice(title: choice.title, chosen: theme == choice) { theme = choice }
                }
            }
            SetupLine("This window shows it now; the panel follows.", muted: true)
        }
        HUDSection(title: "Shortcut", linked: false) {
            HUDReadout(label: "Opens your Aegis", value: hotKey ?? "None free")
            SetupLine(
                hotKey == nil
                    ? "Every Aegis shortcut is taken by another app: open Aegis from its menu bar icon."
                    : "Opens and closes the panel from any app.",
                muted: true
            )
        }
    }
}

struct SilenceScreen: View {
    let model: PanelModel

    var body: some View {
        HUDSection(title: "Silent until opened", first: true, linked: false) {
            SetupLine("While the panel is closed, Aegis makes no sound and shows no notifications. It works quietly in the background.")
        }
        HUDSection(title: "Menu bar", linked: false) {
            SetupSwitch(title: "Glow the menu bar icon when something urgent waits", isOn: Binding(
                get: { model.glowEnabled }, set: { model.glowEnabled = $0 }
            ))
        }
    }
}

/// An on/off choice with its label.
struct SetupSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: HUD.space2) {
            Text(title).hudType(.body)
            Spacer()
            SetupChoice(title: "On", chosen: isOn) { isOn = true }
            SetupChoice(title: "Off", chosen: !isOn) { isOn = false }
        }
    }
}

enum SetupLink {
    static func open(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMail() {
        if let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            NSWorkspace.shared.openApplication(at: mail, configuration: .init())
        }
    }

    /// `fdesetup status`, which any user may run; nil when it can't say.
    static func fileVaultOn() async -> Bool? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
            process.arguments = ["status"]
            let output = Pipe()
            process.standardOutput = output
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(bytes: data, encoding: .utf8) ?? ""
            return text.contains("FileVault is On") ? true : text.contains("FileVault is Off") ? false : nil
        }.value
    }
}

extension HUDTheme {
    /// The owner's theme (#28), in Aegis's settings; the panel and the wizard read it.
    static let storeKey = "hudTheme"

    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// The tune-up (DESIGN.md screen 14, ADR-0030): once the model is in place, one synthetic job through AegisCore and
/// the real model, timed. If the 9B is too slow here, Aegis fetches the 4B and switches to it.
struct TuneUpScreen: View {
    let app: SetupApp
    private var downloads: ModelDownloads {
        .shared
    }

    @State private var metrics: ModelMetrics?
    @State private var verdict: String?
    @State private var problem: String?
    @State private var running = false

    var body: some View {
        let model = ModelChoice.current
        HUDSection(title: "Models", code: SetupText.model(model), first: true, linked: false) {
            SetupDownloadMeter()
            switch downloads.state {
            case .idle: SetupLine("Waiting to start.", muted: true)
            case .downloading: SetupLine("Downloading in the background; carry on with setup.", muted: true)
            case .ready: SetupLine("In place on this Mac and checked.", muted: true)
            case let .failed(why): SetupLine("Stopped: \(why)", tone: HUD.warn)
            }
        }
        HUDSection(title: "Tune-up", linked: false) {
            if running {
                HStack(spacing: HUD.space3) {
                    HUDTag(word: "Running", tone: HUD.primary)
                    SetupLine("About 30 seconds: Aegis loads its model and writes a short test answer, with nothing of yours.")
                }
            }
            if let metrics {
                Grid(alignment: .leading, horizontalSpacing: HUD.space8, verticalSpacing: HUD.space4) {
                    GridRow {
                        HUDReadout(label: "Load", value: metrics.loadSeconds.map { String(format: "%.1f", $0) } ?? "Warm", unit: "s")
                        HUDReadout(
                            label: "First word",
                            value: metrics.firstTokenSeconds.map { String(format: "%.1f", $0) } ?? "–",
                            unit: "s"
                        )
                        HUDReadout(label: "Speed", value: SetupText.speed(metrics), unit: "tokens/s", tone: HUD.primary)
                        HUDReadout(label: "Memory", value: metrics.peakMemoryBytes.map { HUDFormat.bytes(Double($0)) } ?? "–")
                    }
                }
            }
            if let verdict {
                SetupLine(verdict)
            }
            if let problem {
                SetupLine(problem, tone: HUD.warn)
            }
            Button(metrics == nil ? "Run tune-up" : "Run again") { Task { await run() } }
                .buttonStyle(HUDChipStyle())
                .disabled(running || downloads.state != .ready)
        }
        // It runs by itself once the model is in place.
        .task(id: downloads.state) {
            if downloads.state == .ready, metrics == nil, problem == nil {
                await run()
            }
        }
    }

    private func run() async {
        running = true
        problem = nil
        defer { running = false }
        guard case let .tuneUp(measured) = await app.model.service.handle(.tuneUp) else {
            problem = "The model didn't answer. Aegis tries again when it next needs it."
            return
        }
        metrics = measured
        let current = ModelChoice.current
        let tuned = current.tuned(measured)
        guard tuned != current else {
            verdict = "\(SetupText.model(current)) runs well on this Mac."
            return
        }
        verdict = "\(SetupText.model(current)) is slow on this Mac, so Aegis is fetching \(SetupText.model(tuned)) to use instead."
        guard await downloads.fetch([tuned.files]), let folder = ModelChoice.aegisFolder, (try? tuned.choose(in: folder)) != nil else {
            problem = "Couldn't switch models; Aegis keeps \(SetupText.model(current))."
            return
        }
        verdict = "Switched to \(SetupText.model(tuned)), which suits this Mac better."
    }
}

/// The background downloads' progress; shown on every screen while they run (DESIGN.md "Wizard rules").
struct SetupDownloadMeter: View {
    var body: some View {
        let downloads = ModelDownloads.shared
        HUDMeter(
            label: "Download", value: downloads.fraction,
            display: downloads.total > 0
                ? "\(HUDFormat.bytes(Double(downloads.received))) of \(HUDFormat.bytes(Double(downloads.total)))"
                : HUDFormat.percent(downloads.fraction),
            size: .small
        )
    }
}

import AegisKit
import AppKit
import Contacts
import SwiftUI

// MARK: - 11 Personality

/// How Aegis talks: the four presets, its name (also a wake word), what it calls the owner, tone sliders and free
/// notes, with a preview of the chosen style. Presets, name, address and notes are Aegis's own personality, saved
/// through AegisCore a moment after the owner stops typing.
struct PersonalityScreen: View {
    @Bindable var setup: SetupModel
    let model: PanelModel
    @State private var chosen = Personality.standard
    @State private var loaded = false
    @State private var ownerName: String?

    var body: some View {
        SetupColumns {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: HUD.space3), GridItem(.flexible())], spacing: HUD.space3) {
                ForEach(Personality.Style.allCases, id: \.self) { style in
                    HUDChoiceCard(
                        title: style.title,
                        description: SetupText.tagline(style),
                        selected: chosen.style == style,
                        badge: style == .classic ? "Rec" : nil,
                        compact: true
                    ) { chosen.style = style }
                }
            }
            HUDTermInput(prompt: "name >", text: $chosen.name, hint: "also the wake word").padding(.top, HUD.space2)
            HUDSettingRow(label: "Calls you", compact: true) {
                HUDSegmented(label: "Calls you", options: [
                    HUDOption(value: "name", label: "Your name", disabled: ownerName == nil),
                    HUDOption(value: "sir", label: "Sir"), HUDOption(value: "maam", label: "Ma’am"), HUDOption(
                        value: "none",
                        label: "Nothing"
                    ),
                ], value: address, small: true)
            }
            HStack(alignment: .top, spacing: HUD.space4) {
                slider("formality", "Formality", 6, ("Casual", "Formal"))
                slider("humour", "Humour", 5, ("Dry", "Playful"))
                slider("detail", "Detail", 4, ("Brief", "Thorough"))
                slider("warmth", "Warmth", 5, ("Cool", "Warm"))
            }
            .padding(.top, HUD.space3)
            HUDTermInput(prompt: "notes >", text: $chosen.notes, placeholder: "e.g. \"swear a bit\", \"roast me\"", hint: "optional")
                .padding(.top, HUD.space2)
            if chosen.cleaned == nil {
                Text("The name needs letters only, up to 24; notes up to 600 characters.").font(HUDFace.text(11)).foregroundStyle(HUD.warn)
            }
        } side: {
            HUDSubhead(title: "Live preview", meta: chosen.style.title, first: true)
            VStack(alignment: .leading, spacing: HUD.space2) {
                HUDChatLine(who: "you", text: "who’s waiting on me?")
                HUDChatLine(who: chosen.name.lowercased(), text: SetupText.sample(chosen.style), aegis: true, typing: true).id(chosen.style)
            }
            .padding(.vertical, HUD.space3).padding(.horizontal, HUD.space4)
            .background(HUD.surface)
            .overlay(Rectangle().strokeBorder(HUD.glassEdge, lineWidth: 1))
            SetupNote("Tone only. Facts and priorities are the same in every style. It applies to the voice, briefs and answers.")
                .padding(.top, HUD.space3)
        }
        .task {
            await model.loadPersonality()
            chosen = model.personality
            loaded = true
            ownerName = SetupText.ownerFirstName()
        }
        // Saved through AegisCore a moment after the owner stops typing.
        .task(id: chosen) {
            try? await Task.sleep(for: .milliseconds(600))
            guard loaded, !Task.isCancelled, let clean = chosen.cleaned, clean != model.personality else { return }
            _ = await model.savePersonality(clean)
        }
    }

    /// The address as a choice; a custom one (typed in Personality… before) matches none.
    private var address: Binding<String> {
        Binding(get: {
            switch chosen.callOwner.lowercased() {
            case "": "none"
            case "sir": "sir"
            case "ma’am", "ma'am": "maam"
            case ownerName?.lowercased() ?? "\u{0}": "name"
            default: "custom"
            }
        }, set: { pick in
            chosen.callOwner = switch pick {
            case "name": ownerName ?? ""
            case "sir": "sir"
            case "maam": "ma’am"
            default: ""
            }
        })
    }

    private func slider(_ key: String, _ label: String, _ recommended: Int, _ ends: (String, String)) -> some View {
        HUDRangeSlider(label: label, value: setup.number("tone." + key, recommended), range: 0 ... 10, ticks: 24, ends: ends)
    }
}

// MARK: - 12 Voice

/// How Aegis sounds: voice on or off, which voice, three tone sliders, the wake word (live), and a spoken preview in
/// the chosen personality with the reactor pulsing while it speaks.
struct VoiceScreen: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    @State private var listening = false
    @State private var playing = false

    var body: some View {
        let voiceOn = setup.flag("voice", true)
        let which = setup.option("voiceName", "aegis")
        let name = app.model.personality.name
        SetupColumns {
            HUDSettingRow(label: "Voice", hint: "Aegis speaks only while the panel is open.") { HUDToggle(on: voiceOn, label: "Voice") }
            VStack(spacing: HUD.space3) {
                HUDChoiceCard(
                    title: "Aegis · Kokoro",
                    description: "Expressive, with natural pacing and emphasis. Runs entirely on this Mac.",
                    selected: which.wrappedValue == "aegis",
                    badge: "Rec",
                    meta: SetupText.voiceSize,
                    compact: true
                ) {
                    which.wrappedValue = "aegis"
                }
                HUDChoiceCard(
                    title: "System voice",
                    description: "Apple’s best installed English voice. Also the fallback.",
                    selected: which.wrappedValue == "system",
                    meta: "0 GB",
                    compact: true
                ) { which.wrappedValue = "system" }
            }
            .padding(.top, HUD.space3)
            .opacity(voiceOn.wrappedValue ? 1 : 0.45)
            HStack(alignment: .top, spacing: HUD.space4) {
                voiceSlider("warmth", "Warmth", 6, ("Cool", "Warm"), on: voiceOn.wrappedValue)
                voiceSlider("speed", "Speed", 5, ("Slower", "Faster"), on: voiceOn.wrappedValue)
                voiceSlider("scifi", "Sci-fi", 3, ("Human", "AI"), on: voiceOn.wrappedValue)
            }
            .padding(.top, HUD.space3)
            HUDSettingRow(label: "Wake word", hint: "Say \"\(name)\" or \"Hey Aegis\" to open the panel.") {
                HUDToggle(on: Binding(get: { listening }, set: { on in
                    listening = on
                    Task { await app.wake.set(enabled: on) }
                }), label: "Wake word")
            }
            .padding(.top, HUD.space1)
            if let problem = app.wake.problem {
                Text(problem).font(HUDFace.text(11)).foregroundStyle(HUD.warn)
            }
        } side: {
            SetupCentre {
                HUDReactorCore(mode: playing ? .speaking : .idle, size: 240, label: "Voice")
                Group {
                    if playing {
                        HUDChatLine(who: "", text: SetupText.sample(app.model.personality.style), aegis: true, typing: true)
                    } else {
                        SetupNote("press play to hear it in the \(app.model.personality.style.title) style")
                    }
                }
                .frame(minHeight: 36)
                Button(playing ? "Speaking" : "Play preview") { play() }
                    .buttonStyle(HUDPlateStyle(kind: .primary, compact: true))
                    .disabled(!voiceOn.wrappedValue || playing)
                Button("Hear the Pro voice") {}
                    .buttonStyle(HUDPlateStyle(compact: true))
                    .disabled(true)
                    .help("Only one voice ships with Aegis so far")
            }
        }
        .onAppear { listening = app.wake.enabled }
    }

    private func voiceSlider(_ key: String, _ label: String, _ recommended: Int, _ ends: (String, String), on: Bool) -> some View {
        HUDRangeSlider(
            label: label,
            value: setup.number("voice." + key, recommended),
            range: 0 ... 10,
            ticks: 30,
            ends: ends,
            showsValue: false,
            disabled: !on
        )
    }

    private func play() {
        playing = true
        app.model.voice.speak(SetupText.sample(app.model.personality.style))
        Task {
            try? await Task.sleep(for: .seconds(1))
            while app.model.voice.speaking {
                try? await Task.sleep(for: .milliseconds(200))
            }
            playing = false
        }
    }
}

// MARK: - 13 Interface

/// How the panel opens and looks (the theme is live: this window follows it), AegisShell and desktop widgets.
struct InterfaceScreen: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        SetupColumns(kind: .halves) {
            HUDSettingRow(
                label: "Panel hotkey",
                hint: app.hotKey == nil ? "Every Aegis shortcut is taken by another app: open Aegis from its menu bar icon." : nil
            ) {
                HUDKeyCaps(keys: SetupText.keys(app.hotKey ?? "----"))
                Button("Change") {}.buttonStyle(HUDPlateStyle(compact: true)).disabled(true).help("Aegis picks the first free shortcut")
            }
            HUDSubhead(title: "Theme", meta: "try one: this screen follows")
            HStack(spacing: HUD.space2) {
                ForEach(HUDTheme.allCases, id: \.self) { choice in
                    ThemeSwatch(theme: choice, chosen: theme == choice) { theme = choice }
                }
            }
            .padding(.vertical, HUD.space2)
            HUDSettingRow(label: "Panel size") {
                HUDSegmented(label: "Panel size", options: [
                    HUDOption(value: "full", label: "Full screen"), HUDOption(value: "large", label: "Large"), HUDOption(
                        value: "compact",
                        label: "Compact"
                    ),
                ], value: setup.option("panelSize", "full"), small: true)
            }
            HUDSettingRow(label: "Position") {
                HUDSegmented(
                    label: "Position",
                    options: [HUDOption(value: "centre", label: "Centre"), HUDOption(value: "top", label: "Top")],
                    value: setup.option("panelPosition", "centre"),
                    small: true
                )
            }
            HUDSettingRow(label: "Menu bar icon") {
                HUDSegmented(label: "Menu bar icon", options: [
                    HUDOption(value: "reactor", label: "Reactor"), HUDOption(value: "hex", label: "Hex"), HUDOption(
                        value: "mono",
                        label: "Mono"
                    ),
                ], value: setup.option("menuIcon", "reactor"), small: true)
            }
        } side: {
            HUDSubhead(title: "AegisShell", meta: "a shell over macOS, on demand", first: true)
            SetupParagraph(
                "Hides the Dock and menu bar and turns the desktop into a live HUD. Dismiss it and normal macOS comes straight back."
            )
            .padding(.bottom, HUD.space2)
            HUDSettingRow(label: "Engage with") { HUDKeyCaps(keys: ["⌃", "⌥", "A"]) }
            HUDSettingRow(label: "Voice phrase", hint: app.wake.enabled ? nil : "Needs the wake word (Voice).", dim: !app.wake.enabled) {
                Text("\"\(app.model.personality.name), engage\"").font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
            }
            HUDSettingRow(label: "Engage automatically", hint: "On a Mac mini hub, or when a workspace starts.") {
                HUDToggle(on: setup.flag("shellAuto", false), label: "Engage automatically")
            }
            HUDSubhead(title: "Desktop widgets")
            HUDSettingRow(label: "Widgets", hint: "Status, waiting on you, next up, home. Native macOS widgets, almost no cost.") {
                HUDToggle(on: setup.flag("widgets", true), label: "Desktop widgets")
            }
        }
    }
}

/// One theme as a little HUD: a glowing primary bar, an accent dot and a strip of meter bars, in that theme's colours.
private struct ThemeSwatch: View {
    let theme: HUDTheme
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(theme.color(.void))
                    Rectangle().fill(theme.color(.primary)).frame(height: 2).shadow(color: theme.color(.primary), radius: 3)
                        .padding(.leading, 6).padding(.trailing, 18).offset(y: 8)
                    Rectangle().fill(theme.color(.accent)).frame(width: 6, height: 6).frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 6).offset(y: 6)
                    HStack(spacing: 2) {
                        ForEach(0 ..< 14, id: \.self) { _ in Rectangle().fill(theme.color(.primary)).frame(width: 1) }
                    }
                    .opacity(0.7).frame(height: 10).padding(.leading, 6).offset(y: 24)
                }
                .frame(height: 40)
                .overlay(Rectangle().strokeBorder(theme.color(.frame), lineWidth: 1))
                Text(theme.title).hudCaps(9, tracking: 0.16).foregroundStyle(HUD.ink)
            }
            .padding(6)
            .overlay(Rectangle().strokeBorder(chosen ? HUD.primary : HUD.glassEdge, lineWidth: 1))
            .hudGlow(active: chosen)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

// MARK: - 14 Silence and alerts

/// The few exceptions to silence: the menu bar glow (live), breaking silence for emergencies and who may, and home
/// warnings at night; with a preview of the menu bar.
struct SilenceScreen: View {
    @Bindable var setup: SetupModel
    let model: PanelModel
    @State private var vips: [String] = []

    var body: some View {
        let breaks = setup.flag("breakSilence", false)
        SetupColumns {
            HUDSettingRow(label: "Menu bar glow", hint: "A soft glow on the icon when something urgent waits. No sound, no pop-up.") {
                HUDToggle(on: Binding(get: { model.glowEnabled }, set: { model.glowEnabled = $0 }), label: "Menu bar glow")
            }
            HUDSettingRow(
                label: "Break silence for emergencies",
                hint: "Lets a few people and emergency-type messages raise a Mac alert. Off unless you turn it on."
            ) {
                HUDToggle(on: breaks, label: "Break silence for emergencies")
            }
            HUDSubhead(title: "Who can break it", meta: "\(vips.count) VIPs")
            SetupChips(
                items: .constant(vips),
                empty: "No VIPs yet. Mark someone as a VIP in the panel and they appear here.",
                removable: false,
                dim: !breaks.wrappedValue
            )
            SetupNote("Correct it any time in the panel: \"anything from my boss is always important\".")
            HUDSettingRow(label: "Home warnings at night", hint: "The garage or a door left open after dark.", dim: !breaks.wrappedValue) {
                HUDToggle(on: setup.flag("nightHome", false), label: "Home warnings at night").disabled(!breaks.wrappedValue)
            }
            .padding(.top, HUD.space2)
        } side: {
            HUDSubhead(title: "Your menu bar", first: true)
            HStack(spacing: HUD.space4) {
                Spacer()
                Text("Wi-Fi")
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(model.glowEnabled ? HUD.primary : HUD.inkMuted)
                    .hudGlow(active: model.glowEnabled)
                Text(Date().formatted(.dateTime.weekday(.abbreviated).hour().minute())).foregroundStyle(HUD.ink)
            }
            .font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
            .padding(.horizontal, HUD.space3)
            .frame(height: 28)
            .background(HUD.surface)
            .overlay(Rectangle().strokeBorder(HUD.glassEdge, lineWidth: 1))
            SetupParagraph(model.glowEnabled ? "Glowing means something urgent is waiting. Open the panel to see it."
                : "No glow. Everything waits silently in the panel.")
                .padding(.top, HUD.space3)
            SetupCentre { HUDAsciiArt(shape: .galaxy, cols: 34, rows: 14, label: "Quiet") }.padding(.top, HUD.space4)
            SetupNote("While the panel is closed: no sounds, voice, banners or phone pushes.")
        }
        .task {
            if case let .rules(rules) = await model.service.handle(.rules) {
                vips = rules.vip.values.sorted()
            }
        }
    }
}

// MARK: - 15 Tune-up

/// The tune-up (DESIGN.md, ADR-0030): once the model is in place, one synthetic job through AegisCore and the real
/// model, timed. If the 9B is too slow here, Aegis fetches the 4B and switches to it. Next waits while it runs.
struct TuneUpScreen: View {
    let app: SetupApp
    @Binding var tuning: Bool
    @State private var metrics: ModelMetrics?
    @State private var verdict: String?
    @State private var problem: String?
    @State private var began: Date?

    var body: some View {
        let downloads = ModelDownloads.shared
        SetupColumns(kind: .lead) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let seconds = began.map { context.date.timeIntervalSince($0) } ?? 0
                let progress = metrics != nil ? 1 : tuning ? min(0.95, seconds / 30) : 0
                VStack(alignment: .leading, spacing: HUD.space4) {
                    HUDMeter(
                        label: metrics != nil ? "Tuned" : tuning ? "Tuning…" : downloads.state == .ready ? "Ready" : "Waiting",
                        value: progress,
                        size: .large,
                        tone: metrics != nil ? HUD.ok : HUD.primary
                    )
                    VStack(alignment: .leading, spacing: 0) { log }.frame(minHeight: 150, alignment: .top)
                    if let metrics {
                        HUDTermSection(title: "Chosen for this Mac", tone: HUD.ok, rows: [
                            .init(label: "Brain", value: SetupText.model(.current) + " · 4-bit"),
                            .init(label: "Speed", value: SetupText.speed(metrics) + " tokens/s"),
                            .init(label: "Memory", value: metrics.peakMemoryBytes.map { HUDFormat.bytes(Double($0)) } ?? "----"),
                            .init(label: "Stays", value: "loaded only while it works"),
                        ])
                    }
                }
            }
        } side: {
            SetupCentre {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = began.map { Int(context.date.timeIntervalSince($0)) } ?? 0
                    HUDReactorCore(mode: tuning ? .thinking : .idle, size: 300, label: "Tune-up", value: "\(min(seconds, 99))s")
                }
            }
        }
        // It runs by itself once the model is in place.
        .task(id: downloads.state) {
            if downloads.state == .ready, metrics == nil, problem == nil {
                await run()
            }
        }
    }

    @ViewBuilder private var log: some View {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        HUDLogRow(time: "00:00", source: "cores", level: .info, message: "\(cores) cores")
        HUDLogRow(time: "00:00", source: "memory", level: .info, message: "\(ProcessInfo.processInfo.physicalMemory >> 30) GB")
        switch ModelDownloads.shared.state {
        case .downloading, .idle:
            HUDLogRow(
                time: "00:00",
                source: "model",
                level: .info,
                message: ModelDownloads.shared.total > 0 ? "downloading \(SetupText.gigabytes(.shared)); the test starts after"
                    : "waiting for the model download; the test starts after"
            )
        case let .failed(why):
            HUDLogRow(time: "00:00", source: "model", level: .warn, message: "download stopped: \(why)")
        case .ready:
            EmptyView()
        }
        if let metrics {
            let at = { (seconds: Double?) in String(format: "00:%02d", Int(min(seconds ?? 0, 59))) }
            HUDLogRow(
                time: at(metrics.loadSeconds),
                source: "model",
                level: .act,
                message: metrics.loadSeconds
                    .map { String(format: "loaded %@ in %.1f s", SetupText.model(.current), $0) } ?? "already loaded"
            )
            HUDLogRow(
                time: at((metrics.loadSeconds ?? 0) + (metrics.generateSeconds ?? 0)),
                source: "speed",
                level: .ok,
                message: "\(SetupText.speed(metrics)) tok/s, first token " + (metrics.firstTokenSeconds.map { String(
                    format: "%.1f s",
                    $0
                ) } ?? "–")
            )
        }
        if let verdict {
            HUDLogRow(time: "00:30", source: "model", level: .act, message: verdict)
        }
        if let problem {
            HUDLogRow(time: "00:30", source: "model", level: .err, message: problem)
        }
    }

    private func run() async {
        tuning = true
        began = Date()
        problem = nil
        defer { tuning = false }
        guard case let .tuneUp(measured) = await app.model.service.handle(.tuneUp) else {
            problem = "The model didn't answer. Aegis tries again when it next needs it."
            return
        }
        metrics = measured
        let current = ModelChoice.current
        let tuned = current.tuned(measured)
        guard tuned != current else {
            verdict = "\(SetupText.model(current)) runs well on this Mac"
            return
        }
        verdict = "\(SetupText.model(current)) is slow here; fetching \(SetupText.model(tuned))"
        guard await ModelDownloads.shared.fetch([tuned.files]), let folder = ModelChoice.aegisFolder,
              (try? tuned.choose(in: folder)) != nil
        else {
            problem = "Couldn't switch models; Aegis keeps \(SetupText.model(current))."
            return
        }
        verdict = "switched to \(SetupText.model(tuned)), which suits this Mac better"
    }
}

// MARK: - 16 Ready

/// The summary, the READY banner and the speaking core, then Aegis introduces itself in its personality.
struct ReadyScreen: View {
    @Bindable var setup: SetupModel
    let app: SetupApp
    @State private var banner: [String] = []
    @State private var sources = 0
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        let wizard = setup.wizard
        let personality = app.model.personality
        let addons = SetupText.addons.filter { setup.flag("addon." + $0.key, $0.key == "perf").wrappedValue }.map(\.name)
        let homeOn = setup.flag("home", true).wrappedValue
        SetupColumns(kind: .lead) {
            HUDAsciiText(lines: banner, cols: banner.map(\.count).max() ?? 0, size: 6, tone: HUD.ink)
                .accessibilityLabel("Ready")
                .task { banner = HUDBanner.lines("Ready", rows: 14) }
            Text("\(wizard.storageGB) GB assigned · \(personality.style.title) personality · \(sources) sources · "
                + (homeOn ? "home control on" : "home off") + " · brief ready at \(SetupText.time(wizard.briefMinutes))")
                .font(HUDFace.mono(12)).foregroundStyle(HUD.ink)
                .padding(.vertical, HUD.space3).padding(.horizontal, HUD.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().strokeBorder(HUD.glassEdge, lineWidth: 1))
                .overlay(alignment: .leading) { Rectangle().fill(HUD.primary).frame(width: 2) }
                .padding(.vertical, HUD.space3)
            HUDTermSection(title: "Summary", rows: [
                .init(label: "Storage", value: "\(wizard.storageGB) GB · \(SetupText.band(wizard).title) band"),
                .init(label: "Sources", value: "\(sources) readable now"),
                .init(label: "Addons", value: addons.isEmpty ? "None yet" : addons.joined(separator: ", ")),
                .init(label: "Voice", value: setup.flag("voice", true).wrappedValue ? "\(personality.name) · Kokoro" : "Off"),
                .init(label: "Panel", value: "\(app.hotKey ?? "Menu bar") · \(theme.title) theme"),
            ])
            HUDChatLine(
                who: personality.name.lowercased(),
                text: SetupText.hello(personality, briefAt: wizard.briefMinutes),
                aegis: true,
                typing: true
            )
            .padding(.top, HUD.space3)
            switch ModelDownloads.shared.state {
            case .downloading: SetupNote("Models are still downloading; Aegis finishes them in the background.")
            case .failed: SetupNote("The model download stopped; run setup again from the menu to retry.")
            case .idle, .ready: EmptyView()
            }
        } side: {
            SetupCentre { HUDReactorCore(mode: .speaking, size: 300, label: personality.name, value: "Online") }
        }
        .task {
            if case let .status(status) = await app.model.service.handle(.status) {
                sources = status.sources.filter(\.readable).count
            }
        }
    }
}

// MARK: - Text and links

extension SetupModel {
    /// A 0–10 choice, as `option`.
    func number(_ key: String, _ recommended: Int) -> Binding<Int> {
        let text = option(key, String(recommended))
        return Binding(get: { Int(text.wrappedValue) ?? recommended }, set: { text.wrappedValue = String($0) })
    }
}

enum SetupText {
    /// "7:00 am", in the Mac's own format.
    static func time(_ minutes: Int) -> String {
        let minutes = (minutes + 24 * 60) % (24 * 60)
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())?
            .formatted(date: .omitted, time: .shortened) ?? ""
    }

    /// "Qwen3.5-9B".
    static func model(_ choice: ModelChoice) -> String {
        choice.folderName.replacingOccurrences(of: "-MLX-4bit", with: "")
    }

    /// The model's size in billions of parameters, "9".
    static func parameters(_ choice: ModelChoice) -> String {
        model(choice).split(separator: "-").last.map { String($0.dropLast()) } ?? "----"
    }

    /// Tokens a second, the tune-up's speed.
    static func speed(_ metrics: ModelMetrics) -> String {
        guard let tokens = metrics.generationTokens, let seconds = metrics.generateSeconds, seconds > 0 else { return "–" }
        return String(format: "%.0f", Double(tokens) / seconds)
    }

    /// Whole gigabytes, as the storage slider counts them.
    static func gb(_ bytes: UInt64) -> Int {
        Int(bytes / 1_000_000_000)
    }

    /// "3.5 / 11.7 GB" for the downloads, or the total alone before they start.
    @MainActor static func gigabytes(_ downloads: ModelDownloads) -> String {
        guard downloads.total > 0 else { return "----" }
        return String(format: "%.1f / %.1f GB", Double(downloads.received) / 1e9, Double(downloads.total) / 1e9)
    }

    /// Splits a shortcut's label into its keys: "⌥Space" is ⌥ and Space.
    static func keys(_ label: String) -> [String] {
        let modifiers = label.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        let key = label.dropFirst(modifiers.count)
        return modifiers + (key.isEmpty ? [] : [String(key)])
    }

    /// The model band: Lite under 20 GB of memory, Pro with 32 GB and 50 GB assigned, otherwise Standard.
    enum Band: CaseIterable {
        case lite, standard, pro

        var title: String {
            switch self {
            case .lite: "Lite"
            case .standard: "Standard"
            case .pro: "Pro"
            }
        }

        var reach: String {
            switch self {
            case .lite: "small-memory Macs"
            case .standard: "from about 20 GB"
            case .pro: "from about 50 GB"
            }
        }
    }

    static func band(_ wizard: SetupWizard) -> Band {
        if wizard.mac.memoryBytes < 20_000_000_000 {
            return .lite
        }
        return wizard.mac.memoryBytes >= 32 << 30 && wizard.storageGB >= 50 ? .pro : .standard
    }

    /// The disk Aegis keeps its data on, "Macintosh HD".
    static let volumeName = (try? URL(fileURLWithPath: NSHomeDirectory(
    )).resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "This Mac"

    /// The voice Aegis ships with, measured in the app.
    static let voiceSize: String = {
        let voice = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/AegisVoice.xpc")
        return HUDFormat.bytes(Double(folderBytes(voice)))
    }()

    /// What the storage assignment holds: the model files for this Mac, the voice and app in Aegis.app, the addons
    /// ticked, and the rest for the owner's data.
    struct Part {
        let name: String
        let gigabytes: Double
        let tone: HUDToken
    }

    static func budget(_ wizard: SetupWizard) -> [Part] {
        let model = Double(ModelChoice.forMemory(wizard.mac.memoryBytes).files.bytes + ModelFiles.meaning.bytes) / 1e9
        let voice = Double(folderBytes(Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/AegisVoice.xpc"))) / 1e9
        let app = max(0, Double(appBytes) / 1e9 - voice)
        let addons = addons.filter { wizard.answers[option: "addon." + $0.key].map { $0 == "on" } ?? ($0.key == "perf") }
            .map(\.gigabytes).reduce(0, +)
        let data = max(0, Double(wizard.storageGB) - model - voice - app - addons)
        return [
            Part(name: "Main model", gigabytes: model, tone: .primary), Part(name: "Voice", gigabytes: voice, tone: .accent),
            Part(name: "App, runtime", gigabytes: app, tone: .inkMuted), Part(name: "Addons", gigabytes: addons, tone: .warn),
            Part(name: "Your data", gigabytes: data, tone: .frame),
        ]
    }

    private static let appBytes = folderBytes(Bundle.main.bundleURL)

    private static func folderBytes(_ folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    /// The addons offered in setup, ahead of the addon library (DESIGN.md "Addons").
    struct Addon {
        let key: String
        let name: String
        let shape: HUDAscii.Shape
        let gigabytes: Double
        let about: String
        let reads: String
        let can: String
    }

    static let addons = [
        Addon(
            key: "perf",
            name: "Performance Monitor",
            shape: .cube,
            gigabytes: 0.18,
            about: "Live CPU, memory, GPU, disk, network, temperature and battery. Answers \"why is my Mac slow?\"",
            reads: "system stats",
            can: "only read"
        ),
        Addon(
            key: "mail",
            name: "Mail",
            shape: .helix,
            gigabytes: 0.24,
            about: "Aegis’s own mail app, built to match. Your Apple Mail accounts stay as they are.",
            reads: "Mail store",
            can: "send with your OK"
        ),
        Addon(
            key: "calendar",
            name: "Calendar",
            shape: .helix,
            gigabytes: 0.12,
            about: "A calendar in the Aegis style, with meeting prep beside each event.",
            reads: "calendars",
            can: "create events"
        ),
        Addon(
            key: "notes",
            name: "Notes",
            shape: .helix,
            gigabytes: 0.09,
            about: "Notes Aegis can write into and search, linked back to the chat.",
            reads: "Notes",
            can: "write notes"
        ),
        Addon(
            key: "files",
            name: "Files",
            shape: .helix,
            gigabytes: 0.15,
            about: "Find, preview and act on documents by asking.",
            reads: "folders you pick",
            can: "move files with your OK"
        ),
        Addon(
            key: "music",
            name: "Music",
            shape: .wave,
            gigabytes: 0.16,
            about: "Plays, queues and picks music for the moment.",
            reads: "listening history",
            can: "control playback"
        ),
    ]

    /// Each preset in a few words.
    static func tagline(_ style: Personality.Style) -> String {
        switch style {
        case .classic: "Polite, composed, dry wit"
        case .friendly: "Warm, casual, upbeat"
        case .professional: "Crisp, efficient"
        case .none: "Pure information"
        }
    }

    /// The same example reply in each style, for the previews.
    static func sample(_ style: Personality.Style) -> String {
        switch style {
        case .classic: "Sarah’s been waiting since yesterday. I suspect she’s noticed."
        case .friendly: "Heads up, Sarah’s still waiting on you from yesterday!"
        case .professional: "Sarah: awaiting reply, 26 hours."
        case .none: "1 pending reply: Sarah, 26h."
        }
    }

    /// Aegis introducing itself at the end of setup.
    static func hello(_ personality: Personality, briefAt minutes: Int) -> String {
        let name = personality.name
        let time = time(minutes)
        return switch personality.style {
        case .classic: "Hello. I’m \(name). I’m reading what’s already here; your first brief will be waiting at \(time). Until then I’ll keep quiet."
        case .friendly: "Hey! I’m \(name). All set up. Your first brief lands at \(time)."
        case .professional: "\(name) online. First brief at \(time)."
        case .none: "Ready. Brief \(time)."
        }
    }

    /// The owner's first name from their own card in Contacts, when Aegis may read Contacts.
    static func ownerFirstName() -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: [CNContactGivenNameKey as CNKeyDescriptor])
        return me.map(\.givenName).flatMap { $0.isEmpty ? nil : $0 }
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

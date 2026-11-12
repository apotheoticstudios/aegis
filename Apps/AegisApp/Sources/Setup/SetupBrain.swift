import AegisKit
import SwiftUI

/// The Brain step (ADR-0038): this Mac's models, or Claude through the owner's plan, with its model, effort and the
/// switches for what it may read. Settings' Brain page adds the hand-off (#223). Shared through `BrainSettings`.
struct BrainScreen: View {
    /// Settings' Brain page: the hand-off to Claude or ChatGPT and the API keys too.
    var handOff = false
    @Bindable private var settings = BrainSettings.shared
    @State private var automatic = CloudKeys.automatic
    @State private var chatGPTPlan = CloudKeys.useChatGPTPlan
    @State private var claudePlan = CloudKeys.useClaudePlan

    var body: some View {
        SetupColumns {
            VStack(spacing: HUD.space3) {
                HUDChoiceCard(
                    title: "On this Mac",
                    description: "Aegis's own models. Nothing you ask, and nothing Aegis reads, leaves this Mac.",
                    selected: settings.brain == .local, badge: "Rec", compact: true
                ) { settings.brain = .local }
                HUDChoiceCard(
                    title: "Claude",
                    description: "Your Claude plan, through Claude Code. Deeper answers; what it reads goes to Anthropic.",
                    selected: settings.brain == .claude, meta: settings.installed ? "your plan" : "Claude Code not installed",
                    compact: true, disabled: !settings.installed && settings.brain != .claude
                ) { settings.brain = .claude }
            }
            if settings.brain == .claude {
                claudeRows
            }
            if handOff {
                handOffRows
            }
        } side: {
            let healthy = settings.checked && settings.status == nil
            SetupCentre {
                HUDAsciiArt(shape: settings.brain == .claude ? .wave : .radar, cols: 34, rows: 15, tone: HUD.primary, label: "Brain")
                HUDTag(
                    word: settings.brain == .claude ? (healthy ? "Claude" : "Check Claude Code") : "This Mac",
                    tone: settings.brain == .claude && !healthy ? HUD.warn : HUD.ok
                )
                SetupParagraph(Text(settings.brain == .claude ? Brain.leaves
                        : "Every answer is worked out on this Mac. You can switch to Claude at any time in Settings."))
                if settings.brain == .claude, let status = settings.status {
                    SetupNote(status)
                }
            }
        }
        .onAppear(perform: checkClaude)
        .onChange(of: settings.brain) { _, _ in checkClaude() }
        .onChange(of: claudePlan) { _, on in
            CloudKeys.useClaudePlan = on
            checkClaude()
        }
        .onChange(of: chatGPTPlan) { _, on in CloudKeys.useChatGPTPlan = on }
        .onChange(of: automatic) { _, on in CloudKeys.automatic = on }
    }

    /// Checks Claude Code when the brain, or the hand-off through the owner's plan, would use it.
    private func checkClaude() {
        if settings.brain == .claude || (handOff && claudePlan && settings.installed) {
            settings.check()
        }
    }

    @ViewBuilder private var claudeRows: some View {
        HUDSubhead(title: "Claude")
        modelRows
        HUDSubhead(title: "What Claude may read", meta: "\(settings.reads.count) of \(ClaudeTools.Category.allCases.count) on")
        ForEach(ClaudeTools.Category.allCases, id: \.self) { category in
            HUDSettingRow(label: category.label, compact: true) {
                HUDToggle(on: Binding(get: { settings.reads.contains(category) }, set: { on in
                    if on {
                        settings.reads.insert(category)
                    } else {
                        settings.reads.remove(category)
                    }
                }), label: category.label, showState: false)
            }
        }
    }

    /// Claude's model and effort, the same for the brain and the hand-off.
    @ViewBuilder private var modelRows: some View {
        HUDSettingRow(label: "Model", hint: "The models your plan includes, as Claude Code lists them.") {
            let models = settings.models.isEmpty ? [ClaudeCode.Model(value: settings.choice.model, name: "Recommended")] : settings.models
            HUDSegmented(
                label: "Model",
                options: models.map { HUDOption(value: $0.value, label: $0.name) },
                value: $settings.choice.model,
                small: true
            )
        }
        HUDSettingRow(label: "Effort") {
            HUDSegmented(
                label: "Effort", options: ClaudeCode.Effort.allCases.map { HUDOption(value: $0, label: $0.label) },
                value: $settings.choice.effort, small: true
            )
        }
    }

    /// Handing general questions to Claude or ChatGPT: only the owner's own words, billed to their plan or key.
    @ViewBuilder private var handOffRows: some View {
        HUDSubhead(title: "Hand-off", meta: "your own words, nothing personal")
        SetupParagraph(
            "Aegis can hand questions that need more depth to Claude or ChatGPT, and shows the answer here. Only your own words go, "
                + "and only for questions with nothing personal in them: never your messages, mail, calendar, contacts or memory. "
                + "Each answer is billed to your API account (usually a few cents)."
        )
        .padding(.bottom, HUD.space2)
        HUDSettingRow(
            label: "Hand off automatically",
            hint: "Complex general questions go without asking. Say \u{201C}Ask ChatGPT\u{2026}\u{201D} for an answer, or "
                + "\u{201C}Get ChatGPT to make\u{2026}\u{201D} for a task: it works in its own folder in Aegis Tasks and starts "
                + "when you press Start."
        ) {
            HUDToggle(on: $automatic, label: "Hand off automatically")
        }
        if PlanRunner.codex != nil {
            HUDSettingRow(
                label: "Use my ChatGPT plan",
                hint: "Through the ChatGPT app, no key needed. It counts against your plan's limits; an OpenAI key below, if saved, "
                    + "is used instead."
            ) {
                HUDToggle(on: $chatGPTPlan, label: "Use my ChatGPT plan")
            }
        }
        if settings.installed {
            HUDSettingRow(
                label: "Use my Claude plan",
                hint: claudePlan && settings.brain != .claude ? settings.status ?? Self.claudePlanNote : Self.claudePlanNote
            ) {
                HUDToggle(on: $claudePlan, label: "Use my Claude plan")
            }
            if claudePlan, settings.brain != .claude {
                modelRows
            }
        }
        SetupKeyRow(
            name: "Claude API key", site: "platform.claude.com",
            isSaved: { CloudKeys.hasKey(.claude) }, save: { CloudKeys.set($0, for: .claude) }, remove: { CloudKeys.set("", for: .claude) }
        )
        SetupKeyRow(
            name: "OpenAI API key", site: "platform.openai.com",
            isSaved: { CloudKeys.hasKey(.chatgpt) }, save: { CloudKeys.set($0, for: .chatgpt) },
            remove: { CloudKeys.set("", for: .chatgpt) }
        )
    }

    private static let claudePlanNote = "Through Claude Code, no key needed. It counts against your Claude plan's limits; a Claude key "
        + "below, if saved, is used instead."
}

import AegisKit
import SwiftUI

/// The Brain step (ADR-0038): this Mac's models, or Claude through the owner's plan, with its model, effort and the
/// switches for what it may read. Shared with the Claude and ChatGPT window through `BrainSettings`.
struct BrainScreen: View {
    @Bindable private var settings = BrainSettings.shared

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
        } side: {
            let healthy = settings.checked && settings.status == nil
            SetupCentre {
                HUDAsciiArt(shape: settings.brain == .claude ? .wave : .radar, cols: 34, rows: 15, tone: HUD.primary, label: "Brain")
                HUDTag(
                    word: settings.brain == .claude ? (healthy ? "Claude" : "Check Claude Code") : "This Mac",
                    tone: settings.brain == .claude && !healthy ? HUD.warn : HUD.ok
                )
                SetupParagraph(Text(settings.brain == .claude ? Brain.leaves
                        : "Every answer is worked out on this Mac. You can switch to Claude at any time in Claude and ChatGPT settings."))
                if settings.brain == .claude {
                    SetupNote(settings.status ?? Brain.pending)
                }
            }
        }
        .onAppear {
            if settings.brain == .claude {
                settings.check()
            }
        }
        .onChange(of: settings.brain) { _, brain in
            if brain == .claude {
                settings.check()
            }
        }
    }

    @ViewBuilder private var claudeRows: some View {
        HUDSubhead(title: "Claude")
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
}

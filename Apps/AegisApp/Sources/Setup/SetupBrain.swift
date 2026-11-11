import AegisKit
import SwiftUI

/// The Brain step (ADR-0038): this Mac's models, or Claude through the owner's plan, with its model, effort and the
/// switches for what it may read. Kept with Aegis's settings rather than the wizard's answers, as Settings changes it.
struct BrainScreen: View {
    @State private var brain = Brain.current
    @State private var choice = ClaudeCodeRunner.choice
    @State private var models = ClaudeCodeRunner.models
    @State private var reads = ClaudeReads.enabled
    @State private var status: String?
    private let installed = ClaudeCodeRunner.executable != nil

    var body: some View {
        SetupColumns {
            VStack(spacing: HUD.space3) {
                HUDChoiceCard(
                    title: "On this Mac",
                    description: "Aegis's own models. Nothing you ask, and nothing Aegis reads, leaves this Mac.",
                    selected: brain == .local, badge: "Rec", compact: true
                ) { brain = .local }
                HUDChoiceCard(
                    title: "Claude",
                    description: "Your Claude plan, through Claude Code. Deeper answers; what it reads goes to Anthropic.",
                    selected: brain == .claude, meta: installed ? "your plan" : "Claude Code not installed", compact: true,
                    disabled: !installed
                ) { brain = .claude }
            }
            if brain == .claude {
                HUDSubhead(title: "Claude")
                HUDSettingRow(label: "Model", hint: "The models your plan includes, as Claude Code lists them.") {
                    HUDSegmented(
                        label: "Model",
                        options: (models.isEmpty ? [ClaudeCode.Model(value: choice.model, name: "Recommended")] : models)
                            .map { HUDOption(value: $0.value, label: $0.name) },
                        value: $choice.model,
                        small: true
                    )
                }
                HUDSettingRow(label: "Effort") {
                    HUDSegmented(
                        label: "Effort",
                        options: ClaudeCode.Effort.allCases.map { HUDOption(value: $0, label: $0.label) },
                        value: $choice.effort,
                        small: true
                    )
                }
                HUDSubhead(title: "What Claude may read", meta: "\(reads.count) of \(ClaudeTools.Category.allCases.count) on")
                ForEach(ClaudeTools.Category.allCases, id: \.self) { category in
                    HUDSettingRow(label: category.label, compact: true) {
                        HUDToggle(on: Binding(get: { reads.contains(category) }, set: { on in
                            if on {
                                reads.insert(category)
                            } else {
                                reads.remove(category)
                            }
                        }), label: category.label, showState: false)
                    }
                }
            }
        } side: {
            SetupCentre {
                HUDAsciiArt(shape: brain == .claude ? .wave : .radar, cols: 34, rows: 15, tone: HUD.primary, label: "Brain")
                HUDTag(
                    word: brain == .claude ? (status == nil ? "Claude" : "Check Claude Code") : "This Mac",
                    tone: brain == .claude && status != nil ? HUD.warn : HUD.ok
                )
                SetupParagraph(Text(brain == .claude ? Brain.leaves
                        : "Every answer is worked out on this Mac. You can switch to Claude at any time in Claude and ChatGPT settings."))
                if brain == .claude {
                    SetupNote(status ?? Brain.pending)
                }
            }
        }
        .onAppear(perform: check)
        .onChange(of: brain) { _, brain in
            Brain.current = brain
            check()
        }
        .onChange(of: choice) { _, choice in ClaudeCodeRunner.choice = choice }
        .onChange(of: reads) { _, reads in ClaudeReads.enabled = reads }
    }

    /// Asks Claude Code who's signed in and which models the plan offers, without sending anything to Claude.
    private func check() {
        guard brain == .claude, installed else { return }
        status = "Checking Claude Code…"
        Task {
            let ending = await ClaudeCodeRunner().check()
            models = ClaudeCodeRunner.models
            status = Brain.status(ending)
        }
    }
}

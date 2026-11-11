import AegisKit
import AppKit
import SwiftUI

/// Claude and ChatGPT settings (#223): the brain (ADR-0038), the owner's API keys (kept in the Keychain) and
/// automatic hand-off.
struct CloudSettingsView: View {
    @State private var brain = Brain.current
    @State private var reads = ClaudeReads.enabled
    @State private var claudeKey = ""
    @State private var openAIKey = ""
    @State private var saved: [CloudHandOff.Provider: Bool] = [:]
    @State private var automatic = CloudKeys.automatic
    @State private var chatGPTPlan = CloudKeys.useChatGPTPlan
    @State private var claudePlan = CloudKeys.useClaudePlan
    @State private var claudeChoice = ClaudeCodeRunner.choice
    @State private var claudeModels = ClaudeCodeRunner.models
    @State private var claudeStatus: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude and ChatGPT").font(.title3.weight(.semibold))
            brainRows
            Divider()
            Text("Hand-off").font(.headline)
            Text(
                "Aegis can hand questions that need more depth to Claude or ChatGPT, and shows the answer here. "
                    + "Only your own words go, and only for questions with nothing personal in them: never your "
                    + "messages, mail, calendar, contacts or memory. Each answer is billed to your API account "
                    + "(usually a few cents)."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if PlanRunner.codex != nil {
                Toggle("Use my ChatGPT plan through the ChatGPT app (no key needed)", isOn: $chatGPTPlan)
                    .onChange(of: chatGPTPlan) { _, on in CloudKeys.useChatGPTPlan = on }
                Text("It counts against your ChatGPT plan's limits. An OpenAI key below, if saved, is used instead.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if ClaudeCodeRunner.executable != nil {
                claudePlanRows
            }
            keyRow(.claude, placeholder: "Claude API key (platform.claude.com)", text: $claudeKey)
            keyRow(.chatgpt, placeholder: "OpenAI API key (platform.openai.com)", text: $openAIKey)
            Toggle("Hand off complex general questions automatically", isOn: $automatic)
                .onChange(of: automatic) { _, on in CloudKeys.automatic = on }
            Text("Say “Ask ChatGPT…” for an answer, or “Get ChatGPT to make…” for a task: it works in its own folder "
                + "in Aegis Tasks and starts when you press Start.").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            for provider in CloudHandOff.Provider.allCases {
                saved[provider] = CloudKeys.hasKey(provider)
            }
            checkClaude()
        }
    }

    /// What Aegis thinks with (ADR-0038), and with Claude, what it may read.
    @ViewBuilder private var brainRows: some View {
        Text("Brain").font(.headline)
        Picker("Aegis thinks with", selection: $brain) {
            Text("On this Mac").tag(Brain.local)
            Text("Claude (your plan)").tag(Brain.claude)
        }
        .pickerStyle(.segmented)
        .disabled(ClaudeCodeRunner.executable == nil && brain == .local)
        .onChange(of: brain) { _, brain in
            Brain.current = brain
            checkClaude()
        }
        if ClaudeCodeRunner.executable == nil {
            Text("Install Claude Code, and sign in with your Claude plan, to choose Claude.").font(.callout).foregroundStyle(.secondary)
        }
        if brain == .claude {
            modelRows
            Text(Brain.leaves + " " + Brain.pending).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading
            ) {
                ForEach(ClaudeTools.Category.allCases, id: \.self) { category in
                    Toggle(category.label, isOn: Binding(get: { reads.contains(category) }, set: { on in
                        if on {
                            reads.insert(category)
                        } else {
                            reads.remove(category)
                        }
                        ClaudeReads.enabled = reads
                    }))
                }
            }
            if let claudeStatus {
                Text(claudeStatus).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The owner's Claude plan through Claude Code for the hand-off (ADR-0038).
    @ViewBuilder private var claudePlanRows: some View {
        Toggle("Use my Claude plan through Claude Code (no key needed)", isOn: $claudePlan)
            .onChange(of: claudePlan) { _, on in
                CloudKeys.useClaudePlan = on
                checkClaude()
            }
        if claudePlan {
            if brain != .claude {
                modelRows
            }
            Text(brain == .claude ? "It counts against your Claude plan's limits. A Claude key below, if saved, is used instead."
                : claudeStatus ?? "It counts against your Claude plan's limits. A Claude key below, if saved, is used instead.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Claude's model and effort, the same for the brain and the hand-off.
    private var modelRows: some View {
        HStack {
            Picker("Model", selection: $claudeChoice.model) {
                ForEach(claudeModels.isEmpty ? [ClaudeCode.Model(value: claudeChoice.model, name: "Recommended")] : claudeModels) {
                    Text($0.name).tag($0.value)
                }
            }
            Picker("Effort", selection: $claudeChoice.effort) {
                ForEach(ClaudeCode.Effort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        .onChange(of: claudeChoice) { _, choice in ClaudeCodeRunner.choice = choice }
    }

    /// Asks Claude Code who's signed in and which models the plan offers, without sending anything to Claude.
    private func checkClaude() {
        guard claudePlan || brain == .claude, ClaudeCodeRunner.executable != nil else { return }
        claudeStatus = "Checking Claude Code…"
        Task {
            let ending = await ClaudeCodeRunner().check()
            claudeModels = ClaudeCodeRunner.models
            claudeStatus = Brain.status(ending)
        }
    }

    private func keyRow(_ provider: CloudHandOff.Provider, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            SecureField(saved[provider] == true ? "\(provider.name): key saved" : placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                notice = CloudKeys.set(text.wrappedValue, for: provider) ? nil : "The Keychain didn't save that key."
                saved[provider] = CloudKeys.hasKey(provider)
                text.wrappedValue = ""
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Remove") {
                CloudKeys.set("", for: provider)
                saved[provider] = false
            }
            .disabled(saved[provider] != true)
        }
    }
}

/// The settings window, opened from the menu bar menu.
@MainActor
enum CloudSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: CloudSettingsView()))
            created.title = "Claude and ChatGPT"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

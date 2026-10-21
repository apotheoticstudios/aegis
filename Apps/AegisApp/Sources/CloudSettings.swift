import AegisKit
import AppKit
import SwiftUI

/// Claude and ChatGPT settings (#223): the owner's API keys (kept in the Keychain) and automatic hand-off.
struct CloudSettingsView: View {
    @State private var claudeKey = ""
    @State private var openAIKey = ""
    @State private var saved: [CloudHandOff.Provider: Bool] = [:]
    @State private var automatic = CloudKeys.automatic
    @State private var chatGPTPlan = CloudKeys.useChatGPTPlan
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude and ChatGPT").font(.title3.weight(.semibold))
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

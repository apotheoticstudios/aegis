import AegisKit
import AppKit
import SharedIPC
import SwiftUI

/// Aegis lives in the menu bar: no Dock icon, no windows until the panel is opened. Silent while closed.
@main
struct AegisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(delegate: delegate)
        } label: {
            if case .unavailable = delegate.model.phase {
                Image(systemName: delegate.model.phase.symbol)
            } else {
                Image(nsImage: ReactorIcon.image(glowing: delegate.model.glow))
            }
        }
    }
}

/// Owns the panel, its model and the global hotkey for the app's lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// A team-signed install registers AegisCore and ModelService and reads the brief from AegisCore over
    /// XPC; a development build (unsigned, never registered) shows the synthetic sample brief.
    let model: PanelModel = switch BackgroundParts.register() {
    case .registered: .init(service: CoreXPCClient())
    case .skippedUnsigned, .failed: .init(service: SampleCoreService())
    }
    private lazy var panel = BriefPanelController(model: model)
    /// "Hey Aegis" (#204): opt-in, on-device; off until the owner switches it on from the menu.
    let wake = WakeListener()
    private var hotKey: GlobalHotKey?
    private var talkKey: GlobalHotKey?
    @Published private(set) var hotKeyLabel: String?
    @Published private(set) var talkKeyLabel: String?

    func applicationDidFinishLaunching(_: Notification) {
        DiagnosticLog.shared.startSession()
        if DiagnosticLog.shared.isEnabled {
            NSSetUncaughtExceptionHandler(persistUnhandledException)
        }
        // ⌥Space first; other apps (the ChatGPT app, for one) may already own it, so fall back in order.
        for choice in GlobalHotKey.Choice.preferred {
            if let registered = GlobalHotKey(choice, action: { [weak self] in self?.togglePanel() }) {
                hotKey = registered
                hotKeyLabel = choice.label
                break
            }
        }
        for choice in GlobalHotKey.Choice.talk {
            if let registered = GlobalHotKey(choice, number: 2, action: { [weak self] in self?.talk() }) {
                talkKey = registered
                talkKeyLabel = choice.label
                break
            }
        }
        wake.isPanelOpen = { [weak self] in self?.panel.isVisible == true }
        wake.isPlayingReply = { [weak self] in self?.model.voice.speaking == true }
        wake.playbackText = { [weak self] in self?.model.voice.spokenText ?? "" }
        wake.interruptSpeech = { [weak self] in self?.model.interruptSpeech() }
        wake.captureFailed = { [weak self] in self?.model.voice.inputFailed() }
        wake.openPanel = { [weak self] in self?.panel.show() }
        panel.visibilityChanged = { [weak self] open in self?.wake.panelChanged(open: open) }
        WorldWindow.shared.openPanel = { [weak self] in self?.panel.show() }
        WorldWindow.shared.talk = { [weak self] in Task { await self?.model.talk() } }
        model.questionFinished = { [weak self] in self?.wake.answerFinished() }
        wake.isAnswering = { [weak self] in
            if case .asking = self?.model.askState {
                return true
            }
            return false
        }
        wake.conversationEnded = { [weak self] in self?.model.endVoiceConversation() }
        // "Yes" says the moment Aegis starts listening (owner's choice, #311); the voice is warmed at launch so it's quick.
        wake.acknowledge = { [weak self] in self?.model.voice.speak("Yes") }
        wake.ask = { [weak self] question in
            Task { await self?.model.submit(question, spoken: true) }
        }
        wake.isSpeaking = { [weak self] in
            guard let voice = self?.model.voice else { return false }
            return voice.speaking || voice.isListening
        }
        // App tests run inside Aegis with the owner's settings: they must not open the microphone (#305).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { [wake] in await wake.start() }
            model.voice.prepare(enabled: wake.enabled)
        }
        Task { await model.refresh() }
        // The glow: look for a new brief every 5 minutes (a small local request; nothing runs on the model).
        Task { [model] in
            while !Task.isCancelled {
                await model.checkForNewBrief()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        if !model.isSample {
            // A real install: ask once for Contacts, Calendar and Reminders (names and today's schedule).
            Task { await Permissions.requestIfNeeded() }
        }
    }

    func togglePanel() {
        panel.toggle()
    }

    func talk() {
        panel.talk()
    }

    func applicationWillTerminate(_: Notification) {
        WorldWindow.shared.shutDown()
        DiagnosticLog.shared.stopSession()
    }
}

private func persistUnhandledException(_: NSException) {
    DiagnosticLog.shared.record(.uncaughtException)
    DiagnosticLog.shared.flush()
}

/// The menu bar menu.
struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Button("Open your Aegis" + (delegate.hotKeyLabel.map { "   \($0)" } ?? "")) { delegate.togglePanel() }
        Button("Talk to your Aegis" + (delegate.talkKeyLabel.map { "   \($0)" } ?? "")) { delegate.talk() }
        Button("Refresh brief") { Task { await delegate.model.refresh() } }
        Button(delegate.model.writing ? "Writing a brief…" : "Write a brief now") {
            Task { await delegate.model.writeNow() }
        }
        .disabled(delegate.model.writing || delegate.model.isSample)
        Toggle("Listen for “Hey Aegis”", isOn: Binding(
            get: { delegate.wake.enabled },
            set: { on in Task { await delegate.wake.set(enabled: on) } }
        ))
        if let problem = delegate.wake.problem {
            Text(problem)
        }
        Button("World view") { WorldWindow.shared.show() }
        Button("World view settings…") { WorldKeysWindow.show() }
        Button("Personality…") { PersonalityWindow.show(delegate.model) }
        Button("Claude and ChatGPT…") { CloudSettingsWindow.show() }
        Toggle("Glow for urgent items", isOn: Binding(
            get: { delegate.model.glowEnabled },
            set: { delegate.model.glowEnabled = $0 }
        ))
        if delegate.hotKeyLabel == nil {
            Text("No shortcut: every Aegis shortcut is taken by another app")
        }
        Divider()
        Button("Quit Project: Aegis") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

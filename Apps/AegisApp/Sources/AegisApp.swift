import AegisKit
import AppKit
import SharedIPC
import SwiftUI

/// Aegis lives in the menu bar: no Dock icon, no windows until the panel is opened. Silent while closed.
@main
struct AegisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // While AegisShell is on, its own item (ShellMenuBarItems) stands in for this one.
        MenuBarExtra(isInserted: Binding(get: { !ShellController.shared.isOn }, set: { _ in })) {
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
            // While AegisShell is engaged, ⌥Space opens its launcher instead (the design's Launcher), but an open panel
            // still closes with it.
            if let registered = GlobalHotKey(choice, action: { [weak self] in
                guard let self else { return }
                if ShellController.shared.isOn, !panel.isVisible {
                    ShellLauncher.shared.toggle()
                } else {
                    togglePanel()
                }
            }) {
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
        // AegisShell's voice overlay counts as the open panel: echo cancellation while it speaks, follow-ups.
        wake.isPanelOpen = { [weak self] in self?.panel.isVisible == true || ShellVoice.shared.isVisible }
        wake.isPlayingReply = { [weak self] in self?.model.voice.speaking == true }
        wake.playbackText = { [weak self] in self?.model.voice.spokenText ?? "" }
        wake.interruptSpeech = { [weak self] in self?.model.interruptSpeech() }
        wake.hearing = { [weak self] words in
            self?.model.voice.hearing = words
            self?.model.voice.heardAll = false
        }
        wake.stoppedTalking = { [weak self] in self?.model.voice.heardAll = true }
        wake.captureFailed = { [weak self] in self?.model.voice.inputFailed() }
        wake.openPanel = { [weak self] in
            self?.model.voice.wakes += 1
            self?.panel.show()
        }
        panel.visibilityChanged = { [weak self] open in
            if open {
                ShellVoice.shared.hide()
            }
            self?.wake.panelChanged(open: open || ShellVoice.shared.isVisible)
        }
        ShellVoice.shared.model = model
        ShellVoice.shared.openPanel = { [weak self] in self?.panel.show() }
        ShellVoice.shared.changed = { [weak self] in
            guard let self else { return }
            wake.panelChanged(open: panel.isVisible || ShellVoice.shared.isVisible)
        }
        WorldWindow.shared.openPanel = { [weak self] in self?.panel.show() }
        let shell = ShellController.shared
        shell.model = model
        shell.openPanel = { [weak self] in self?.panel.show() }
        shell.talk = { [weak self] in self?.talk() }
        shell.panelKey = hotKeyLabel
        shell.talkKey = talkKeyLabel
        shell.start()
        WorldWindow.shared.talk = { [weak self] in Task { await self?.model.talk() } }
        model.questionFinished = { [weak self] in self?.wake.answerFinished() }
        wake.isAnswering = { [weak self] in
            if case .asking = self?.model.askState {
                return true
            }
            return false
        }
        wake.conversationEnded = { [weak self] in self?.model.endVoiceConversation() }
        // "Yes" says the moment Aegis starts listening (owner's choice, #311), from a recording, so the voice itself can
        // stay unloaded while the panel is closed.
        wake.acknowledge = { [weak self] in self?.model.voice.acknowledge() }
        wake.ask = { [weak self] question in
            Task { await self?.model.submit(question, spoken: true) }
        }
        wake.isSpeaking = { [weak self] in
            guard let voice = self?.model.voice else { return false }
            return voice.speaking || voice.isListening
        }
        // App tests run inside Aegis: they must not open the microphone (#305).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { [wake] in await wake.start() }
        }
        Task { await model.refresh() }
        // The glow: look for a new brief every 5 minutes (a small local request; nothing runs on the model).
        Task { [model] in
            while !Task.isCancelled {
                await model.checkForNewBrief()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        // A real install sets itself up on first launch (#26); the wizard asks for access, so nothing else does.
        if !model.isSample, !WorldSidecar.isTestHost, !SetupModel.finished {
            showSetup(again: false)
        }
    }

    /// The setup wizard: on first launch until it's finished, and from the menu to run it again.
    func showSetup(again: Bool) {
        SetupWindow.show(SetupApp(model: model, wake: wake, hotKey: hotKeyLabel), again: again) { [weak self] in
            self?.panel.show()
        }
    }

    func togglePanel() {
        panel.toggle()
    }

    func talk() {
        // In AegisShell with details showing: the voice overlay over any app (ShellVoice) rather than the panel.
        if ShellController.shared.isOn, !ShellController.shared.hideDetails, !panel.isVisible {
            ShellVoice.shared.talk()
        } else {
            panel.talk()
        }
    }

    func applicationWillTerminate(_: Notification) {
        ShellController.shared.shutDown()
        WorldWindow.shared.shutDown()
        DiagnosticLog.shared.stopSession()
    }
}

private func persistUnhandledException(_: NSException) {
    DiagnosticLog.shared.record(.uncaughtException)
    DiagnosticLog.shared.flush()
}

extension UserDefaults {
    /// Aegis's settings. App tests run inside the real Aegis.app, so the test host gets its own domain, emptied at
    /// launch: a test never reads or changes the owner's settings.
    nonisolated(unsafe) static let aegis: UserDefaults = { // UserDefaults is thread-safe, just not marked Sendable.
        let tests = "dev.aegis.app.tests"
        guard WorldSidecar.isTestHost, let store = UserDefaults(suiteName: tests) else { return .standard }
        store.removePersistentDomain(forName: tests)
        return store
    }()
}

/// The menu bar menu.
struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Button("Open your Aegis" + (delegate.hotKeyLabel.map { "   \($0)" } ?? "")) { delegate.togglePanel() }
        Button("Talk to your Aegis" + (delegate.talkKeyLabel.map { "   \($0)" } ?? "")) { delegate.talk() }
        Button("Engage AegisShell" + (ShellController.shared.hotKeyLabel.map { "   \($0)" } ?? "")) {
            Task { await ShellController.shared.engage() }
        }
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
        Button("Run setup again…") { delegate.showSetup(again: true) }
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

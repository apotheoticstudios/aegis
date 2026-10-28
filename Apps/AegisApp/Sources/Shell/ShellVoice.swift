import AppKit
import SwiftUI

/// AegisShell's voice over any app (the design system's ShellVoice): while engaged with details showing, Talk to Aegis
/// shows the voice overlay centred under the menu bar instead of opening the panel; the app in front never moves. It is
/// the panel's own voice turn (the words heard, thinking, the answer as it's spoken), and like the panel an open Aegis
/// surface (silent rule): it fades 3 s after the answer, a click on it or anything needing a confirmation hands over to
/// the panel, and disengaging silences it. With details hidden, Talk opens the panel instead, since the overlay would
/// show your data over whatever is on screen.
@MainActor
@Observable
final class ShellVoice {
    static let shared = ShellVoice()

    /// Set at launch.
    @ObservationIgnored var model: PanelModel?
    @ObservationIgnored var openPanel: () -> Void = {}
    /// The overlay came or went: the wake listener treats it as the open panel (echo cancellation, follow-ups).
    @ObservationIgnored var changed: () -> Void = {}

    /// The ask state from before this turn, so an earlier answer never shows as this one's.
    private(set) var before: PanelModel.AskState = .idle
    @ObservationIgnored private var window: NSPanel?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    var isVisible: Bool {
        window != nil
    }

    /// What the overlay shows of a voice turn: the words heard while listening, then thinking, then the answer.
    struct Turn: Equatable {
        var state: HUDVoiceOverlay.State
        var transcript: String
        var answer = ""
    }

    static func turn(heard: String?, ask: PanelModel.AskState, partial: String) -> Turn {
        if let heard {
            return Turn(state: .listening, transcript: heard)
        }
        return switch ask {
        case let .asking(question): partial.isEmpty
            ? Turn(state: .thinking, transcript: question) : Turn(state: .answering, transcript: question, answer: partial)
        case let .answered(question, answer): Turn(state: .answering, transcript: question, answer: answer.text)
        case let .failed(question, message): Turn(state: .answering, transcript: question, answer: message)
        case .idle: Turn(state: .listening, transcript: "")
        }
    }

    func talk() {
        guard let model else { return }
        before = model.askState
        if window == nil {
            show(model)
        }
        Task { await model.talk() }
        watch(model)
    }

    /// Goes, leaving the voice turn running (the panel takes it over), or silenced when AegisShell disengages.
    func hide(silencing: Bool = false) {
        watcher?.cancel()
        watcher = nil
        guard let window else { return }
        self.window = nil
        if silencing {
            model?.voice.silence()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            window.orderOut(nil)
        }
        changed()
    }

    /// The panel first, so the wake listener sees one open surface throughout; the panel opening takes the overlay away.
    private func handOver() {
        openPanel()
        hide()
    }

    private func show(_ model: PanelModel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let host = FittingHostingView(rootView: ShellVoiceView(voice: self, model: model) { [weak self] in self?.handOver() })
        let size = host.fittingSize
        let area = screen.visibleFrame
        let panel = NSPanel(
            contentRect: NSRect(x: area.midX - size.width / 2, y: area.maxY - 12 - size.height, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = host
        // It grows downwards as the words and the answer arrive, its top kept under the menu bar.
        host.resized = { [weak panel] size in
            guard let panel, size.height > 0 else { return }
            let top = panel.frame.maxY
            panel.setFrame(
                NSRect(x: panel.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                display: true
            )
        }
        panel.orderFrontRegardless()
        window = panel
        changed()
    }

    private func watch(_ model: PanelModel) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var started = false, quiet = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let voice = model.voice
                let asking = if case .asking = model.askState {
                    true
                } else {
                    false
                }
                let busy = voice.isListening || voice.speaking || asking
                started = started || busy
                quiet = busy ? 0 : quiet + 0.25
                // A confirmation is answered in the panel, as is voice that can't be used (it says why).
                let unusable = if case .unavailable = voice.state {
                    quiet >= 1
                } else {
                    false
                }
                if model.pendingTask != nil || ActionPresence.shared.pending != nil || unusable {
                    return handOver()
                }
                // 3 s after the answer; soon when nothing was asked; and never left up if listening didn't start.
                if quiet >= (started ? (model.askState == before ? 0.5 : 3) : 5) {
                    return hide()
                }
            }
        }
    }
}

private struct ShellVoiceView: View {
    let voice: ShellVoice
    let model: PanelModel
    let open: () -> Void
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    var body: some View {
        let heard: String? = if case let .listening(words) = model.voice.state {
            words
        } else {
            nil
        }
        let turn = ShellVoice.turn(heard: heard, ask: model.askState == voice.before ? .idle : model.askState, partial: model.partialAnswer)
        // Typed along with the voice while it reads this very answer; whole otherwise.
        let speaking = model.voice.speaking && !turn.answer.isEmpty && model.voice.spokenText == turn.answer
        HUDVoiceOverlay(
            state: turn.state, transcript: turn.transcript, answer: turn.answer, name: model.personality.name.lowercased(),
            typed: speaking ? Double(model.voice.saidCount ?? turn.answer.count) / Double(turn.answer.count) : 1
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the panel")
        .environment(\.hudTheme, theme)
        .environment(\.colorScheme, .dark)
    }
}

private final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var resized: (CGSize) -> Void = { _ in }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        resized(fittingSize)
    }
}

import AppKit
import SwiftUI

/// A floating panel that the hotkey shows and hides. Escape closes it, except while God's Eye View has it (#303).
@MainActor
final class BriefPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: PanelModel
    private var hudFrame: NSRect?
    private var reportedVisible = false
    /// Opened (true) or closed (false); the wake listener follows it (#313).
    var visibilityChanged: (Bool) -> Void = { _ in }
    var isVisible: Bool {
        panel.isVisible
    }

    init(model: PanelModel) {
        self.model = model
        // The design system's HUD (ADR-0029): most of the screen, up to 1360 × 860.
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: min(1360, screen.width - 60), height: min(860, screen.height - 40)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        // On every Space, including over other full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // The HUD's ground fills the whole window, so the window server needn't blend the desktop behind it.
        panel.isOpaque = true
        panel.backgroundColor = .black
        super.init()
        panel.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: panel
        )
        panel.contentView = NSHostingView(rootView: BriefView(model: model, close: { [weak self] in
            self?.hide()
        }))
        panel.center()
        WorldPresence.shared.presentationChanged = { [weak self] showing in self?.fitWorld(showing) }
    }

    func toggle() {
        if panel.isVisible {
            hide()
            return
        }
        show()
    }

    /// "Hey Aegis": the panel opens (if closed); the wake listener takes the question.
    func show() {
        guard !panel.isVisible else { return }
        NSApp.activate()
        HUDPresence.shared.open = true
        panel.makeKeyAndOrderFront(nil)
        report(visible: true)
        Task { await model.opened() }
    }

    /// "Talk to Aegis": the panel opens (if closed) already listening.
    func talk() {
        show()
        Task { await model.talk() }
    }

    private func fitWorld(_ showing: Bool) {
        if showing {
            guard hudFrame == nil else { return }
            hudFrame = panel.frame
            panel.setFrame(panel.screen?.visibleFrame ?? panel.frame, display: true)
        } else if let hudFrame {
            panel.setFrame(hudFrame, display: true)
            self.hudFrame = nil
        }
    }

    private func hide() {
        HUDPresence.shared.open = false
        panel.orderOut(nil)
        report(visible: false)
        model.panelClosed()
    }

    /// macOS also hides the panel by itself when another app becomes active, so presence follows what is really on
    /// screen: everything that moves or samples stops while the panel is hidden or fully covered, and the wake
    /// listener leaves its open-panel mode while it is hidden.
    @objc private func occlusionChanged() {
        HUDPresence.shared.open = panel.isVisible && panel.occlusionState.contains(.visible)
        report(visible: panel.isVisible)
    }

    private func report(visible: Bool) {
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        visibilityChanged(visible)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        hide()
        return false
    }
}

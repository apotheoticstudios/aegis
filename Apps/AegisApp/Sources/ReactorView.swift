import SceneKit
import SwiftUI

/// The panel's arc reactor (#292): the WebGL prototype (docs/design/prototypes/reactor.html) rebuilt in SceneKit on
/// Metal. A twinkling particle shell, a spinning band, orbiting arcs and a hot core, with bloom. Idle drifts and
/// breathes, thinking spins up, speaking pulses, listening turns amber. It draws only while its window is visible.
struct ReactorView: NSViewRepresentable {
    enum Mode: Equatable {
        case idle, thinking, listening, speaking
    }

    let mode: Mode
    var size: CGFloat = 34

    func makeNSView(context _: Context) -> ReactorSceneView {
        ReactorSceneView(size: size)
    }

    func updateNSView(_ view: ReactorSceneView, context _: Context) {
        view.reactor.mode = mode
        view.setAccessibilityLabel(Self.label(mode))
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: ReactorSceneView, context _: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    static func label(_ mode: Mode) -> String {
        switch mode {
        case .idle: "Aegis"
        case .thinking: "Aegis is thinking"
        case .listening: "Aegis is listening"
        case .speaking: "Aegis is speaking"
        }
    }
}

/// The SceneKit view, see-through so the HUD's grid and glows show behind it; it plays only while its window is visible.
final class ReactorSceneView: SCNView {
    let reactor = ReactorScene()

    init(size: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size), options: nil)
        scene = reactor.scene
        pointOfView = reactor.cameraNode
        delegate = reactor
        backgroundColor = .clear
        antialiasingMode = .multisampling2X
        preferredFramesPerSecond = 30
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("ReactorSceneView is created in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        occlusionChanged()
    }

    /// Nothing animates once the panel closes.
    @objc private func occlusionChanged() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPlaying = visible
        rendersContinuously = visible
    }
}

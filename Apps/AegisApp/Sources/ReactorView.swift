import SceneKit
import SwiftUI

/// The panel's arc reactor (#292): the WebGL prototype (docs/design/prototypes/reactor.html) rebuilt in SceneKit on
/// Metal. A twinkling particle shell, a spinning band, orbiting arcs and a hot core, with bloom, in the theme's colours.
/// Idle holds a frame, thinking spins up, speaking pulses and listening takes the accent.
struct ReactorView: NSViewRepresentable {
    enum Mode: Equatable {
        case idle, thinking, listening, speaking
    }

    let mode: Mode
    var size: CGFloat = 34
    /// Held on its current frame: AegisShell's still frame.
    var still = false

    func makeNSView(context _: Context) -> ReactorSceneView {
        ReactorSceneView(size: size)
    }

    func updateNSView(_ view: ReactorSceneView, context: Context) {
        view.configure(mode: mode, theme: context.environment.hudTheme, held: still || context.environment.accessibilityReduceMotion)
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

/// The SceneKit view plays only during visible, active work.
final class ReactorSceneView: SCNView {
    let reactor = ReactorScene()
    private var held = false

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

    func configure(mode: ReactorView.Mode, theme: HUDTheme, held: Bool) {
        let changed = reactor.mode != mode || reactor.theme != theme
        reactor.mode = mode
        reactor.theme = theme
        self.held = held
        occlusionChanged()
        if changed {
            needsDisplay = true
        }
    }

    @objc private func occlusionChanged() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let moving = visible && !held && reactor.mode != .idle
        if isPlaying != moving {
            isPlaying = moving
        }
        if rendersContinuously != moving {
            rendersContinuously = moving
        }
    }
}

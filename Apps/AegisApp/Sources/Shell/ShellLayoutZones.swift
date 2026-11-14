import AppKit
import SwiftUI

/// The design system's window layout (ShellWindows): before the windows move, their target zones show over the screen as
/// dashed outlines with corner brackets and each app's name, with a dotted path from each window to its zone; the windows
/// then glide into place together and the zones fade. Click-through and never active; it names apps only.
@MainActor
final class ShellLayoutZones {
    /// One window's move, in the overlay's own top-left points.
    struct Zone: Equatable {
        let name: String
        let from: CGRect
        let to: CGRect
    }

    private let window: NSPanel

    /// Shows the moves (in Accessibility's top-left screen points) over `screen`, `primary` being the menu bar's display.
    init(_ moves: [(name: String, from: CGRect, to: CGRect)], screen: NSScreen, primary: NSScreen) {
        let zones = moves.map {
            Zone(
                name: $0.name,
                from: Self.local($0.from, screen: screen.frame, primary: primary.frame),
                to: Self.local($0.to, screen: screen.frame, primary: primary.frame)
            )
        }
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the windows it shows the way for, under menus; it takes no clicks.
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: ShellLayoutZonesView(zones: zones, size: screen.frame.size))
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
    }

    /// Gone at once, as when AegisShell disengages mid-layout.
    func close() {
        window.orderOut(nil)
    }

    /// The zones fade once the windows are in place.
    func fade() {
        let window = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            window.orderOut(nil)
        }
    }

    /// Accessibility's top-left screen points as the overlay's own on `screen` (an AppKit frame), `primary` being the
    /// display whose top Accessibility measures from.
    static func local(_ rect: CGRect, screen: CGRect, primary: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: rect.minY - (primary.maxY - screen.maxY), width: rect.width, height: rect.height)
    }

    /// The frame `progress` of the way from `from` to `to`, eased on the design's standard curve; held at either end.
    static func step(from: CGRect, to: CGRect, progress: Double) -> CGRect {
        let eased = CGFloat(HUDMotion.standard(min(max(progress, 0), 1)))
        func mix(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            start + (end - start) * eased
        }
        return CGRect(
            x: mix(from.minX, to.minX),
            y: mix(from.minY, to.minY),
            width: mix(from.width, to.width),
            height: mix(from.height, to.height)
        )
    }
}

/// The zones themselves: a faint fill, a dashed outline and corner brackets in the signal colour, the app's name in the
/// corner, and the dotted path from where its window is now. Arrives in under 200 ms.
struct ShellLayoutZonesView: View {
    let zones: [ShellLayoutZones.Zone]
    let size: CGSize
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for zone in zones {
                    var path = Path()
                    path.move(to: CGPoint(x: zone.from.midX, y: zone.from.midY))
                    path.addLine(to: CGPoint(x: zone.to.midX, y: zone.to.midY))
                    context.stroke(path, with: .color(theme.color(.primary).opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    context.fill(Path(zone.to), with: .color(theme.color(.primary).opacity(0.06)))
                    context.stroke(Path(zone.to), with: .color(theme.color(.frame)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    context.stroke(HUDBrackets(arm: 18).path(in: zone.to), with: .color(theme.color(.primary)), lineWidth: 2)
                    // Square nodes at either end of the path: where the window is, and where it goes.
                    for (point, tone) in [
                        (CGPoint(x: zone.from.midX, y: zone.from.midY), HUDToken.frame),
                        (CGPoint(x: zone.to.midX, y: zone.to.midY), .primary),
                    ] {
                        context.fill(Path(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(theme.color(tone)))
                    }
                }
            }
            ForEach(zones, id: \.name) { zone in
                Text(zone.name).hudCaps(11, tracking: 0.2)
                    .foregroundStyle(theme.color(.primary))
                    .hudGlow()
                    .offset(x: zone.to.minX + 14, y: zone.to.minY + 12)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: reduced ? 0.1 : 0.18)) { shown = true }
        }
        .environment(\.hudTheme, theme)
        .accessibilityHidden(true)
    }
}

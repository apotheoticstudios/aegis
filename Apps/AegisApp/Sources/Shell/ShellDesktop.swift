import AegisKit
import SwiftUI

/// AegisShell's live desktop on one display (the design system's ShellDesktop): the wash in the workspace's colour and,
/// at the centre, the ReactorCore in today's ScheduleArc with Aegis's one line under it and the readings round it.
/// Engaging builds it (the shield forms and breaks into it, ramp noise flickers and clears); disengaging fades it. The
/// design's frame traced round the screen, with corner brackets, is left out (owner's choice, 2026-10-27).
struct ShellDesktop: View {
    let shell: ShellController
    let size: CGSize
    private let noise: [String]
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(shell: ShellController, size: CGSize) {
        self.shell = shell
        self.size = size
        noise = Self.noise(cols: Int(size.width / 6) + 1, rows: Int(size.height / 12) + 1)
    }

    var body: some View {
        TimelineView(.animation(paused: !moving)) { context in
            let frame = frame(at: context.date)
            ZStack(alignment: .topLeading) {
                wall.opacity(frame.wall)
                if frame.noise > 0 {
                    HUDAsciiText(lines: noise, cols: noise.first?.count ?? 0, size: 12, tone: HUD.primary, aspect: HUDAscii.artAspect)
                        .opacity(frame.noise)
                }
                if frame.shield > 0 {
                    HUDAsciiArt(shape: .shield, cols: 110, rows: 55, grit: 0.12, tone: HUD.primary)
                        .scaleEffect(frame.shieldScale)
                        .opacity(frame.shield)
                        .position(x: size.width / 2, y: size.height / 2)
                }
                let scene = frame.readings * switchFade(context.date)
                ShellScenery(shell: shell, geometry: ShellGeometry(size: size)).mood.opacity(scene)
                if shell.workspace == .work {
                    ShellScenery(shell: shell, geometry: ShellGeometry(size: size)).ground.opacity(scene)
                }
                core.opacity(frame.core)
                caption.opacity(scene)
                ShellReadings(shell: shell, geometry: ShellGeometry(size: size)).opacity(scene)
                if let still = shell.still, still != .covered {
                    stillLine(still).opacity(frame.readings)
                }
            }
            .opacity(frame.all)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.hudTheme, theme)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AegisShell desktop")
    }

    private var moving: Bool {
        switch shell.phase {
        case .engaging, .leaving: true
        case .off, .engaged: shell.switchedAt.map { Date().timeIntervalSince($0) < 0.7 } ?? false
        }
    }

    /// Switching workspace: the readings go at once, then the new scene draws in after 180 ms over 480 ms; a 200 ms
    /// crossfade under Reduce Motion.
    private func switchFade(_ date: Date) -> Double {
        guard let switched = shell.switchedAt else { return 1 }
        let time = date.timeIntervalSince(switched)
        return reduced ? ShellMotion.span(time, 0, 0.2) : HUDMotion.standard(ShellMotion.span(time, 0.18, 0.48))
    }

    private func frame(at date: Date) -> ShellMotion.Frame {
        switch shell.phase {
        case let .engaging(start): ShellMotion.engage(date.timeIntervalSince(start), reduced: reduced)
        case let .leaving(start): ShellMotion.disengage(date.timeIntervalSince(start), reduced: reduced)
        case .off, .engaged: ShellMotion.Frame()
        }
    }

    // MARK: - Geometry: the design's, worked out from the core so it grows on a large display

    private var big: Bool {
        size.width > 2000
    }

    private var centre: CGPoint {
        CGPoint(x: size.width / 2, y: big ? size.height * 0.5 : size.height * 468 / 956)
    }

    private var arcSize: CGFloat {
        big ? 820 : 560
    }

    // MARK: - Layers

    /// The ground: the void with the nebula wash mixed with the workspace's accent (Work's is the theme's own signal). It
    /// fades in over the wallpaper as engaging builds, and out with everything else when leaving.
    private var wall: some View {
        let nebula = theme.rgba(.nebula), accent = theme.rgba(shell.workspace.accent)
        // Each workspace's mood (the design's .wall): the share of nebula and accent, the ellipse's size and centre.
        let mood = ShellMood(shell.workspace)
        let (fromNebula, fromAccent, across, tall, centre) = (mood.nebula, mood.accent, mood.across, mood.tall, mood.centre)
        // CSS's color-mix with transparent: the mix of the two, at their combined share as its opacity.
        let share = fromNebula + fromAccent
        func mix(_ shift: UInt32) -> Double {
            (HUDTheme.channel(nebula, shift) * fromNebula + HUDTheme.channel(accent, shift) * fromAccent) / share
        }
        let wash = Color(.sRGB, red: mix(24), green: mix(16), blue: mix(8), opacity: share)
        // An ellipse `across` of the width by `tall` of the height, fading out at 70% of it.
        return ZStack {
            Rectangle().fill(theme.color(.void))
            // Faded to the same colour at no opacity, not to clear black, so no darker ring shows at its edge.
            EllipticalGradient(colors: [wash, wash.opacity(0)], center: centre, endRadiusFraction: across * 0.7)
                .scaleEffect(x: 1, y: tall / across, anchor: centre)
        }
        .animation(.easeInOut(duration: reduced ? 0.2 : 0.48), value: shell.workspace)
        .frame(width: size.width, height: size.height)
    }

    private var core: some View {
        ZStack {
            if shell.workspace != .movie {
                HUDScheduleArc(events: shell.readings.events, now: shell.readings.now, size: arcSize, hidden: shell.hideDetails)
            }
            ReactorView(mode: mode, size: coreSize, still: shell.still != nil)
        }
        .frame(width: arcSize, height: arcSize)
        .position(centre)
    }

    /// Smaller in Focus and Evening; small, alone, in Movie.
    private var coreSize: CGFloat {
        let full: CGFloat = big ? 360 : 250
        return switch shell.workspace {
        case .work: full
        case .focus: full * 0.8
        case .evening: full * 0.9
        case .movie: 120
        }
    }

    private var mode: ReactorView.Mode {
        guard let model = shell.model else { return .idle }
        if case .asking = model.askState {
            return .thinking
        }
        return model.voice.speaking ? .speaking : model.voice.isListening ? .listening : .idle
    }

    /// The line along the bottom while the desktop holds still, saying why.
    private func stillLine(_ still: ShellStill) -> some View {
        HStack(spacing: 10) {
            Text("Still frame").hudCaps(10, tracking: 0.18).foregroundStyle(HUD.ink)
            Text(still.line).font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Rectangle().fill(HUD.frame).frame(height: 1) }
        .fixedSize()
        .position(x: centre.x, y: size.height - 40 + 12)
    }

    /// Aegis's line under the core: with details hidden, counts and times only.
    private var caption: some View {
        VStack(spacing: 6) {
            Text(shell.model?.personality.name ?? "Aegis").hudCaps(10, tracking: 0.24).foregroundStyle(HUD.primary)
            let line = Self.line(shell.workspace, readings: shell.readings, hidden: shell.hideDetails)
            (Text(line.lead + " ").foregroundStyle(HUD.inkMuted) + Text(line.rest).foregroundStyle(HUD.ink))
                .hudType(.body)
                .multilineTextAlignment(.center)
        }
        .frame(width: 560 * (big ? 1.46 : 1))
        .position(x: centre.x, y: centre.y + arcSize / 2 - 6 + 20)
    }

    /// Aegis's one line in each workspace: Focus names what's next, Movie only says whether anything waits.
    static func line(_ workspace: ShellWorkspace, readings: ShellController.Readings, hidden: Bool) -> (lead: String, rest: String) {
        let next = next(readings.events, now: readings.now, hidden: hidden)
        return switch workspace {
        case .work, .evening: (need(readings.urgent), next)
        case .focus: ("Focus.", next)
        case .movie: ("Movie.", readings.urgent == 0 ? "All clear." : "\(readings.urgent) urgent waiting in the panel.")
        }
    }

    static func need(_ urgent: Int) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        let count = urgent < words.count ? words[urgent] : String(urgent)
        return switch urgent {
        case 0: "All clear."
        case 1: "One thing needs you."
        default: "\(count) things need you."
        }
    }

    static func next(_ events: [HUDScheduleArc.Event], now: Date, hidden: Bool = true) -> String {
        events.first { $0.start > now }.map {
            hidden ? "Your next event is at \(HUDScheduleArc.clock($0.start))." : "\($0.title) at \(HUDScheduleArc.clock($0.start))."
        } ?? "Nothing else today."
    }

    /// Character noise from the density ramp, weighted towards the empty end: the design's seeded generator.
    static func noise(cols: Int, rows: Int) -> [String] {
        var state = 7.0
        let ramp = Array(" .:-=+*#%@")
        return (0 ..< rows).map { _ in
            String((0 ..< cols).map { _ in
                state = (state * 9301 + 49297).truncatingRemainder(dividingBy: 233_280)
                return ramp[min(Int(pow(state / 233_280, 2.2) * 10), 9)]
            })
        }
    }
}

/// A workspace's wash: how much nebula and accent, and the ellipse's size and centre.
struct ShellMood {
    let nebula: Double
    let accent: Double
    let across: Double
    let tall: Double
    let centre: UnitPoint

    init(_ workspace: ShellWorkspace) {
        switch workspace {
        case .work, .focus: (nebula, accent, across, tall, centre) = (0.78, 0.22, 0.42, 0.46, UnitPoint(x: 0.5, y: 0.52))
        case .evening: (nebula, accent, across, tall, centre) = (0.55, 0.3, 0.46, 0.5, UnitPoint(x: 0.5, y: 0.6))
        case .movie: (nebula, accent, across, tall, centre) = (0.35, 0, 0.3, 0.3, UnitPoint(x: 0.5, y: 0.52))
        }
    }
}

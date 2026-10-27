import SwiftUI

/// AegisShell's live desktop on one display (the design system's ShellDesktop): the wash in the workspace's colour,
/// a frame traced round the screen and, at the centre, the ReactorCore in today's ScheduleArc with Aegis's one line
/// under it. Engaging builds it (the shield forms and breaks into it, ramp noise flickers and clears); disengaging
/// fades it. The readings drawn round the core come in later stages (docs/stages/AEGISSHELL.md).
struct ShellDesktop: View {
    let shell: ShellController
    let size: CGSize
    /// The menu bar's height on this display.
    let top: CGFloat
    private let noise: [String]
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(shell: ShellController, size: CGSize, top: CGFloat) {
        self.shell = shell
        self.size = size
        self.top = top
        noise = Self.noise(cols: Int(size.width / 6) + 1, rows: Int(size.height / 12) + 1)
    }

    var body: some View {
        TimelineView(.animation(paused: !moving)) { context in
            let frame = frame(at: context.date)
            ZStack(alignment: .topLeading) {
                wall.opacity(frame.wall)
                trace(frame)
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
                core.opacity(frame.core)
                caption.opacity(frame.readings)
            }
            .opacity(frame.all)
        }
        .frame(width: size.width, height: size.height)
        .background(theme.color(.void))
        .environment(\.hudTheme, theme)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AegisShell desktop")
    }

    private var moving: Bool {
        switch shell.phase {
        case .engaging, .leaving: true
        case .off, .engaged: false
        }
    }

    private func frame(at date: Date) -> ShellMotion.Frame {
        switch shell.phase {
        case let .engaging(start): ShellMotion.engage(date.timeIntervalSince(start), traceLength: traceLength, reduced: reduced)
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

    /// The ground: the nebula wash mixed with the workspace's accent (Work's is the theme's own signal).
    private var wall: some View {
        let nebula = theme.rgba(.nebula), accent = theme.rgba(.primary)
        func mix(_ shift: UInt32) -> Double {
            HUDTheme.channel(nebula, shift) * 0.78 + HUDTheme.channel(accent, shift) * 0.22
        }
        // An ellipse 42% of the width by 46% of the height, fading out at 70% of it.
        return EllipticalGradient(
            colors: [Color(.sRGB, red: mix(24), green: mix(16), blue: mix(8)), .clear],
            center: UnitPoint(x: 0.5, y: 0.52), endRadiusFraction: 0.42 * 0.7
        )
        .scaleEffect(x: 1, y: 0.46 / 0.42, anchor: UnitPoint(x: 0.5, y: 0.52))
        .frame(width: size.width, height: size.height)
    }

    private var traceLength: Double {
        Double(size.width - 16 + size.height - top - 16)
    }

    /// The frame: from the top centre out along both sides to the bottom, with corner brackets.
    private func trace(_ frame: ShellMotion.Frame) -> some View {
        let top = top + 8, bottom = size.height - 8, left = 8.0, right = size.width - 8, middle = size.width / 2, long = 28.0
        let sides = Path { path in
            for edge in [left, right] {
                path.move(to: CGPoint(x: middle, y: top))
                path.addLine(to: CGPoint(x: edge, y: top))
                path.addLine(to: CGPoint(x: edge, y: bottom))
                path.addLine(to: CGPoint(x: middle, y: bottom))
            }
        }
        let brackets = Path { path in
            let corners = [(left, top, 1.0, 1.0), (right, top, -1.0, 1.0), (left, bottom, 1.0, -1.0), (right, bottom, -1.0, -1.0)]
            for (edge, level, across, down) in corners {
                path.move(to: CGPoint(x: edge, y: level + down * long))
                path.addLine(to: CGPoint(x: edge, y: level))
                path.addLine(to: CGPoint(x: edge + across * long, y: level))
            }
        }
        return ZStack {
            sides.trim(from: 0, to: frame.trace).stroke(HUD.frame, lineWidth: 1).opacity(0.38)
            brackets.stroke(HUD.frame, style: StrokeStyle(lineWidth: 2, lineCap: .square)).opacity(0.8 * frame.brackets)
        }
        .opacity(frame.traceFade)
        .allowsHitTesting(false)
    }

    private var core: some View {
        ZStack {
            HUDScheduleArc(events: shell.readings.events, now: shell.readings.now, size: arcSize, hidden: true)
            ReactorView(mode: mode, size: big ? 360 : 250)
        }
        .frame(width: arcSize, height: arcSize)
        .position(centre)
    }

    private var mode: ReactorView.Mode {
        guard let model = shell.model else { return .idle }
        if case .asking = model.askState {
            return .thinking
        }
        return model.voice.speaking ? .speaking : model.voice.isListening ? .listening : .idle
    }

    /// Aegis's line under the core. Counts and times only, never names: the desktop shows behind every window and
    /// during screen sharing, and hiding details by choice comes with the readings.
    private var caption: some View {
        VStack(spacing: 6) {
            Text(shell.model?.personality.name ?? "Aegis").hudCaps(10, tracking: 0.24).foregroundStyle(HUD.primary)
            (Text(Self.need(shell.readings.urgent) + " ").foregroundStyle(HUD.inkMuted)
                + Text(Self.next(shell.readings.events, now: shell.readings.now)).foregroundStyle(HUD.ink))
                .hudType(.body)
                .multilineTextAlignment(.center)
        }
        .frame(width: 560 * (big ? 1.46 : 1))
        .position(x: centre.x, y: centre.y + arcSize / 2 - 6 + 20)
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

    static func next(_ events: [HUDScheduleArc.Event], now: Date) -> String {
        events.first { $0.start > now }.map { "Your next event is at \(HUDScheduleArc.clock($0.start))." } ?? "Nothing else today."
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

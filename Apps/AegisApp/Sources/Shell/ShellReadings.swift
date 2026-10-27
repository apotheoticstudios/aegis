import AegisKit
import SwiftUI

/// The design's layout, worked out from the core so the same composition fits the MacBook and a 27-inch display.
/// Angles are degrees clockwise from the top.
struct ShellGeometry {
    let size: CGSize

    var big: Bool {
        size.width > 2000
    }

    /// How much a large display scales the pieces.
    var scale: CGFloat {
        big ? 1.46 : 1
    }

    var centre: CGPoint {
        CGPoint(x: size.width / 2, y: big ? size.height * 0.5 : size.height * 468 / 956)
    }

    /// The schedule arc's box, its radius, and the core's.
    var arcSize: CGFloat {
        big ? 820 : 560
    }

    var arcRadius: CGFloat {
        arcSize / 2 - 34
    }

    var coreRadius: CGFloat {
        (big ? 360 : 250) / 2
    }

    /// The line under the core, and the ask line under that.
    var captionY: CGFloat {
        centre.y + arcSize / 2 - 6
    }

    var askY: CGFloat {
        captionY + (big ? 104 : 84)
    }

    func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: centre.x + sin(radians) * radius, y: centre.y - cos(radians) * radius)
    }

    /// Where a time of day sits on the schedule arc (06:00 to midnight round 300°).
    func angle(_ date: Date, now: Date) -> Double {
        let minutes = date.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 60
        return -150 + 300 * min(max((minutes - 360) / 1080, 0), 1)
    }
}

/// Every reading drawn round the core (the design system's ShellDesktop): status pinned to the core, next up pinned
/// to its event on the arc, the people waiting on an orbit, the system as arcs under the core, the brief's actions,
/// the ask line and the ground. With details hidden they show counts and kinds, never names or words.
struct ShellReadings: View {
    let shell: ShellController
    let geometry: ShellGeometry
    @AppStorage(HUDTheme.storeKey, store: .aegis) private var theme = HUDTheme.arc

    private var still: Bool {
        shell.still != nil
    }

    private var hidden: Bool {
        shell.hideDetails
    }

    private var readings: ShellController.Readings {
        shell.readings
    }

    var body: some View {
        // Each workspace shows its own readings (the design system's ShellWorkspaceMoods).
        let workspace = shell.workspace
        ZStack(alignment: .topLeading) {
            if workspace == .work || workspace == .evening {
                ShellScenery(shell: shell, geometry: geometry).home
                ShellScenery(shell: shell, geometry: geometry).world
            }
            if workspace == .work {
                stream
                system
                waiting
                status
            }
            if workspace != .movie {
                next
                briefActions
                ask
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    // MARK: - The stream, top left, fading downwards

    private var stream: some View {
        let rows = geometry.big ? 14 : 8
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stream").hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                Spacer()
                Text(hidden ? "live · details hidden" : "live · \(readings.today) today").font(HUDFace.mono(10))
                    .foregroundStyle(HUD.inkMuted)
            }
            .padding(.bottom, 6)
            ForEach(Array(readings.stream.prefix(rows).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(HUDScheduleArc.clock(line.time)).frame(width: 40, alignment: .leading)
                    Text(line.source.uppercased()).font(HUDFace.mono(10)).tracking(0.6).frame(width: 74, alignment: .leading)
                        .foregroundStyle(line.urgent ? HUD.critical : HUD.inkMuted)
                    Text(hidden ? line.hidden : line.text).font(.custom(HUDType.body.fontName, size: 11)).foregroundStyle(HUD.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(HUDFace.mono(11))
                .foregroundStyle(HUD.inkMuted)
                .padding(.vertical, 3)
                .padding(.leading, line.urgent ? 6 : 0)
                .overlay(alignment: .leading) {
                    if line.urgent {
                        Rectangle().fill(HUD.critical).frame(width: 2)
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge.opacity(0.6)).frame(height: 1) }
            }
        }
        .frame(width: geometry.big ? 520 : 360, alignment: .leading)
        .mask(LinearGradient(
            stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
            startPoint: .top,
            endPoint: .bottom
        ))
        .frame(width: 0, height: 0, alignment: .topLeading)
        .position(x: geometry.big ? 56 : 40, y: 70)
    }

    // MARK: - Status, pinned to the core

    private var status: some View {
        let anchor = geometry.point(40, geometry.coreRadius * 0.8), rise = geometry.big ? 236.0 : 182
        let elbow = CGPoint(x: anchor.x + (anchor.y - rise), y: rise)
        return Group {
            if readings.urgent == 0 {
                HUDCallout(
                    anchor: anchor, elbow: elbow, tone: .ok, still: still, code: "Status · core", title: "All clear. Nothing needs you.",
                    text: Self.left(readings.events, now: readings.now), lead: { HUDCalloutValue(value: "00", unit: "Urgent", tone: .ok) },
                    actions: { EmptyView() }
                )
            } else {
                HUDCallout(
                    anchor: anchor, elbow: elbow, tone: .critical, pulse: true, still: still, code: "Status · core",
                    title: hidden ? (readings.topFromPerson ? "From a contact" : "Something urgent") : readings.top,
                    text: hidden ? "Details hidden · show them from Aegis's menu" : "\(readings.items) items in today's brief",
                    width: 400 * geometry.scale,
                    lead: {
                        HStack(spacing: 12) {
                            HUDCalloutValue(
                                value: String(format: "%02d", readings.urgent), unit: "Urgent · \(readings.waiting.count) waiting",
                                tone: .critical
                            )
                            if hidden {
                                HUDAsciiArt(shape: .fingerprint, cols: 8, rows: 4, tone: HUD.accent, animate: !still)
                            }
                        }
                    },
                    actions: { link("Open in panel") { shell.openPanel() } }
                )
            }
        }
    }

    // MARK: - Next up, pinned to its event on the arc

    private var next: some View {
        let now = readings.now
        let upcoming = readings.events.first { $0.start > now }
        return Group {
            if let event = upcoming {
                let anchor = geometry.point(
                    (geometry.angle(event.start, now: now) + geometry.angle(event.end, now: now)) / 2, geometry.arcRadius
                )
                let left = anchor.x < geometry.centre.x, reach = geometry.big ? 210.0 : 153
                HUDCallout(
                    anchor: anchor, elbow: CGPoint(x: anchor.x + (left ? -reach : reach), y: anchor.y + reach), side: left ? .left : .right,
                    still: still, code: "Next up · cal", title: hidden ? "Event" : event.title,
                    text: HUDScheduleArc.clock(event.start) + (hidden ? " · location hidden"
                        : "–" + HUDScheduleArc.clock(event.end) + (event.location.map { " · " + $0 } ?? "")),
                    width: 320 * geometry.scale,
                    lead: {
                        HStack(spacing: 12) {
                            HUDAsciiArt(shape: .hourglass, cols: 12, rows: 7, tone: HUD.primary, animate: !still)
                            let wait = Self.toGo(event.start.timeIntervalSince(now))
                            HUDCalloutValue(value: wait.value, unit: wait.unit)
                        }
                    },
                    actions: { link("Open in panel") { shell.openPanel() } }
                )
            } else {
                let anchor = geometry.point(150, geometry.arcRadius)
                HUDCallout(
                    anchor: anchor, elbow: CGPoint(x: anchor.x + 60, y: anchor.y + 60), tone: .inkMuted, still: still,
                    code: "Next up · cal", title: "Nothing else today", text: nil, actions: { EmptyView() }
                )
            }
        }
    }

    // MARK: - The people waiting, on an orbit

    private var waiting: some View {
        let radius = geometry.arcRadius + (geometry.big ? 84 : 64), people = Array(readings.waiting.prefix(5))
        let start = geometry.point(44, radius)
        return ZStack(alignment: .topLeading) {
            HUDOrbit(size: radius * 2 + 40, rings: [.init(radius: radius, from: 44, to: 128, dashed: true)], still: still)
                .position(geometry.centre)
            Color.clear.frame(width: 0, height: 0)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(people.isEmpty ? "Nobody is waiting on you" : "Waiting on you · \(readings.waiting.count)")
                            .hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
                        if let longest = people.first {
                            Text("longest " + Self.since(readings.now.timeIntervalSince(longest.since))).font(HUDFace.mono(10))
                                .foregroundStyle(HUD.inkMuted)
                        }
                    }
                    .fixedSize()
                }
                .position(x: start.x + 18, y: start.y - 44)
            ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                let angle = 52 + Double(index) * 17, spot = geometry.point(angle, radius)
                let waited = readings.now.timeIntervalSince(person.since)
                HUDSatellite.Dot(tone: Self.tone(waited), pulse: index == 0, still: still).position(spot)
                let out = geometry.point(angle, radius + 16)
                Color.clear.frame(width: 0, height: 0)
                    .overlay(alignment: .leading) {
                        HUDSatellite(
                            label: hidden ? "Contact \(index + 1)" : person.name,
                            value: Self.since(waited),
                            tone: Self.tone(waited)
                        )
                    }
                    .position(out)
            }
        }
    }

    // MARK: - The system as arcs under the core

    private var system: some View {
        let radius = geometry.coreRadius + 31 * geometry.scale, gigabyte = 1_000_000_000.0
        let used = Double(readings.diskUsed) / gigabyte, total = Double(readings.diskTotal) / gigabyte
        let memory = Double(readings.memory) / gigabyte, budget = 3.0
        let anchor = geometry.point(215, radius)
        return ZStack(alignment: .topLeading) {
            HUDOrbit(
                size: radius * 2 + 60,
                arcs: [
                    .init(
                        radius: radius,
                        from: 132,
                        to: 178,
                        value: total > 0 ? used / total : 0,
                        label: String(format: "Disk %.0f/%.0f GB", used, total)
                    ),
                    .init(
                        radius: radius, from: 182, to: 228, value: memory / budget, tone: memory > budget * 0.9 ? .warn : .primary,
                        label: String(format: "Mem %.1f GB", memory)
                    ),
                ],
                rings: [.init(radius: radius - 9 * geometry.scale, ticks: 60, length: 3, major: 5, spin: 4)],
                still: still
            )
            .position(geometry.centre)
            if !readings.problems.isEmpty {
                let names = readings.problems.map(BriefPresentation.name)
                HUDCallout(
                    anchor: anchor, elbow: CGPoint(x: geometry.centre.x - geometry.arcRadius - 22 * geometry.scale, y: anchor.y),
                    side: .left, tone: .warn, still: still, code: "System · \(readings.problems.count) degraded",
                    title: names
                        .count == 1 ? (hidden ? "1 source needs a fix" : "\(names[0]) needs a fix") : "\(names.count) sources need a fix",
                    text: String(format: "Storage %.0f / %.0f GB · memory %.1f GB", used, total, memory),
                    actions: { link("Fix it", tone: .warn) { shell.openPanel() } }
                )
            }
        }
    }

    // MARK: - The brief's actions, under Aegis's line

    private var briefActions: some View {
        HStack(spacing: 12) {
            HUDAsciiArt(shape: .spectrum, cols: 9, rows: 2, grit: 0.05, tone: HUD.primary, animate: !still)
            // AegisShell stays silent (AGENTS.md): the brief is read with the panel open, as everywhere else.
            link("Play brief") {
                shell.openPanel()
                shell.model?.readBrief()
            }
            Rectangle().fill(HUD.line).frame(width: 1, height: 12)
            link("\(readings.items) items", tone: .inkMuted) { shell.openPanel() }
        }
        .fixedSize()
        .position(x: geometry.centre.x, y: geometry.captionY + 56)
    }

    // MARK: - The ask line on the ground

    private var ask: some View {
        Button { ShellLauncher.shared.open() } label: {
            HStack(spacing: 10) {
                Text("aegis ›").font(HUDFace.mono(12)).foregroundStyle(HUD.primary)
                Text(hidden ? "Ask or command" : "Ask or command · try “what's on today?”")
                    .font(.custom(HUDType.body.fontName, size: 12)).foregroundStyle(HUD.inkMuted).lineLimit(1)
                TimelineView(.animation(minimumInterval: 0.55, paused: still)) { context in
                    Rectangle().fill(HUD.primary).frame(width: 7, height: 14)
                        .opacity(still || HUDMotion.blink(context.date.timeIntervalSinceReferenceDate, period: 1.1) ? 0.8 : 0)
                }
                Spacer(minLength: 0)
                if let key = shell.panelKey {
                    HUDKeyCaps(keys: ShellMenu.caps(key))
                }
            }
            .padding(.horizontal, 4)
            .frame(width: 520 * geometry.scale, height: 34)
            .background(LinearGradient(
                stops: [.init(color: theme.color(.primary).opacity(0.09), location: 0), .init(color: .clear, location: 0.8)],
                startPoint: .bottom, endPoint: .top
            ))
            .overlay(alignment: .bottom) { Rectangle().fill(HUD.frame).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button { shell.talk() } label: { ShellIconView(icon: .mic, size: 14).foregroundStyle(HUD.inkMuted) }
                .buttonStyle(.plain)
                .offset(x: 22)
                .accessibilityLabel("Speak")
        }
        .position(x: geometry.centre.x, y: geometry.askY + 17)
        .accessibilityLabel("Ask Aegis")
    }

    private func link(_ title: String, tone: HUDToken = .primary, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(HUDLinkStyle(tone: tone))
    }

    // MARK: - Wording

    /// "25 min to go", or hours once it's further off.
    static func toGo(_ seconds: TimeInterval) -> (value: String, unit: String) {
        let minutes = max(Int((seconds / 60).rounded(.up)), 0)
        return minutes < 100 ? (String(format: "%02d", minutes), "min to go") : ("\(minutes / 60)", "h to go")
    }

    /// "26 h", "52 min".
    static func since(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }

    /// The longer they've waited, the hotter the colour.
    static func tone(_ waited: TimeInterval) -> HUDToken {
        switch waited / 3600 {
        case 24...: .critical
        case 6...: .warn
        case 2...: .ink
        default: .inkMuted
        }
    }

    static func left(_ events: [HUDScheduleArc.Event], now: Date) -> String {
        let count = events.count { $0.end > now }
        return count == 0 ? "Nothing else today" : count == 1 ? "1 event left today" : "\(count) events left today"
    }
}

/// The brief's weather line as the world reading shows it: storm or sun art, a headline and the rest.
struct ShellWeather: Equatable {
    let stormy: Bool
    let headline: String
    let detail: String
    let temperature: String?

    init(_ line: String) {
        let body = line.replacingOccurrences(of: "Weather at home: ", with: "")
        temperature = body.range(of: #"\d+ to \d+°"#, options: .regularExpression).map { String(body[$0]) }
        let rest = body.replacingOccurrences(of: #"^\d+ to \d+°\.\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        stormy = line.contains("Storm") || line.contains("Rain likely") || line.contains("showers")
        headline = line.contains("Storm") ? "Storms" : line.contains("Rain likely") ? "Rain" : line.contains("showers") ? "Showers" : "Clear"
        detail = [temperature, rest.isEmpty ? nil : rest].compactMap(\.self).joined(separator: " · ")
    }
}

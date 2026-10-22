import SwiftUI

/// Whether the panel is on screen. Everything that moves (character art, cable pulses) and every reading the panel
/// takes runs only while it is, so a closed panel costs nothing.
@MainActor @Observable
final class HUDPresence {
    static let shared = HUDPresence()
    var open = false
}

/// One frame for a whole screen (the design system's HudShell): a large glass plate with cut corners and long
/// brackets, a top bar, a body and an optional bottom strip divided by hairlines, and circuit links drawn from the
/// hub (`hudHub`) to each section that feeds it (`hudLink`). `wires` draws them as curved cables with a pulse.
struct HUDShell<Top: View, Content: View, Bottom: View>: View {
    var wires = false
    @ViewBuilder var top: Top
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HUD.space4) { top }
                .padding(.vertical, HUD.space3)
                .padding(.horizontal, HUD.space6)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { HUDRule() }
            content
                .padding(HUD.space6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .backgroundPreferenceValue(HUDLinkKey.self) { targets in
                    GeometryReader { proxy in
                        HUDLinks(layout: HUDLinkLayout(targets: targets, in: proxy, wires: wires), wires: wires)
                    }
                }
            if Bottom.self != EmptyView.self {
                bottom
                    .padding(.horizontal, HUD.space6)
                    .padding(.top, HUD.space4)
                    .padding(.bottom, HUD.space6)
                    .overlay(alignment: .top) { HUDRule() }
            }
        }
        .background { HUDGlass(tone: HUD.frame, cut: HUD.chamferLg, arm: 28, sheen: 0.25) }
    }
}

/// A hairline that means nothing on its own: between the shell's zones and between sections.
struct HUDRule: View {
    var body: some View {
        Rectangle().fill(HUD.glassEdge).frame(height: HUD.strokeHair)
    }
}

/// The shell's hub and the sections it feeds, gathered from the body to draw the circuit links.
struct HUDLinkTarget {
    enum Role {
        case hub, section
    }

    let role: Role
    let bounds: Anchor<CGRect>
    /// The hub's character art, when it is art: links then plug into its outermost solid characters.
    var art: [String] = []
}

struct HUDLinkKey: PreferenceKey {
    static var defaultValue: [HUDLinkTarget] {
        []
    }

    static func reduce(value: inout [HUDLinkTarget], nextValue: () -> [HUDLinkTarget]) {
        value += nextValue()
    }
}

extension View {
    /// Marks the screen's centre instrument, where the shell's circuit links start.
    func hudHub(art: [String] = []) -> some View {
        anchorPreference(key: HUDLinkKey.self, value: .bounds) { [HUDLinkTarget(role: .hub, bounds: $0, art: art)] }
    }

    /// Marks a section the hub feeds: the shell draws a link to its title.
    func hudLink() -> some View {
        anchorPreference(key: HUDLinkKey.self, value: .bounds) { [HUDLinkTarget(role: .section, bounds: $0)] }
    }
}

/// Where the circuit links run, after the design system's HudShell: from the hub's edge (or from the outermost solid
/// character of hub art) to just outside each section's title, left-hand sections from the left, the rest from the
/// right, fanned out so they don't overlap.
struct HUDLinkLayout {
    struct Link {
        var start: CGPoint
        var end: CGPoint
        var path: Path
    }

    var links: [Link] = []

    init(targets: [HUDLinkTarget], in proxy: GeometryProxy, wires: Bool) {
        guard let hub = targets.first(where: { $0.role == .hub }) else {
            self.init(hub: .zero, art: [], sections: [], wires: wires)
            return
        }
        let sections = targets.filter { $0.role == .section }.map { proxy[$0.bounds] }
        self.init(hub: proxy[hub.bounds], art: hub.art, sections: sections, wires: wires)
    }

    init(hub: CGRect, art: [String], sections: [CGRect], wires: Bool) {
        let ink = HUDArtInk(art, in: hub)
        for (list, dir) in [(sections.filter { $0.midX < hub.midX }, -1.0), (sections.filter { $0.midX >= hub.midX }, 1.0)] {
            let sorted = list.sorted { $0.minY < $1.minY }
            let middle = Double(sorted.count - 1) / 2
            for (index, section) in sorted.enumerated() {
                let offset = Double(index) - middle
                let endY = section.minY + 7
                let edge = dir < 0 ? section.maxX + 6 : section.minX - 6
                let start = ink?.anchor(dir: dir, index: index, count: sorted.count)
                    ?? CGPoint(x: hub.midX + dir * (hub.width / 2 * 0.82 - abs(offset) * 10), y: hub.midY + offset * 22)
                var path = Path()
                path.move(to: start)
                if wires {
                    let bend = (start.x + edge) / 2
                    path.addCurve(
                        to: CGPoint(x: edge, y: endY),
                        control1: CGPoint(x: bend, y: start.y),
                        control2: CGPoint(x: bend, y: endY)
                    )
                } else {
                    let turn = (edge + start.x) / 2 + dir * offset * 10
                    path.addLines([start, CGPoint(x: turn, y: start.y), CGPoint(x: turn, y: endY), CGPoint(x: edge, y: endY)])
                }
                links.append(Link(start: start, end: CGPoint(x: edge, y: endY), path: path))
            }
        }
    }
}

/// Hub art's solid characters, so a link can plug into the drawing itself.
private struct HUDArtInk {
    let lines: [String]
    let cell: CGSize
    let origin: CGPoint
    let first: Int
    let last: Int

    init?(_ lines: [String], in box: CGRect) {
        let width = lines.map(\.count).max() ?? 0
        let solid = lines.indices.filter { Self.solidColumns(lines[$0]) != nil }
        guard width > 0, let first = solid.first, let last = solid.last else { return nil }
        self.lines = lines
        cell = CGSize(width: box.width / CGFloat(width), height: box.height / CGFloat(lines.count))
        origin = box.origin
        self.first = first
        self.last = last
    }

    /// The first and last solid character on a line; spaces and the faintest marks don't count.
    static func solidColumns(_ line: String) -> ClosedRange<Int>? {
        let columns = line.enumerated().filter { !" .:-".contains($0.element) }.map(\.offset)
        guard let low = columns.first, let high = columns.last else { return nil }
        return low ... high
    }

    func anchor(dir: Double, index: Int, count: Int) -> CGPoint? {
        let share = count == 1 ? 0.5 : Double(index) / Double(count - 1)
        var row = Int((Double(first) + Double(last - first) * (0.12 + 0.76 * share)).rounded())
        for _ in 0 ..< 6 where row < lines.count {
            if let columns = Self.solidColumns(lines[row]) {
                let column = dir > 0 ? columns.upperBound + 1 : columns.lowerBound
                return CGPoint(x: origin.x + CGFloat(column) * cell.width, y: origin.y + (CGFloat(row) + 0.5) * cell.height)
            }
            row += 1
        }
        return nil
    }
}

private struct HUDLinks: View {
    let layout: HUDLinkLayout
    let wires: Bool
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        ZStack {
            ForEach(layout.links.indices, id: \.self) { index in
                let link = layout.links[index]
                link.path.stroke(HUD.frame, lineWidth: wires ? 1.5 : HUD.strokeHair).opacity(wires ? 0.5 : 0.55)
                Rectangle().fill(HUD.frame).frame(width: 4, height: 4).position(link.start)
                Rectangle().fill(HUD.frame).frame(width: 4, height: 4).position(link.end)
            }
            if wires {
                // A glowing pulse travels each cable from the hub out to its section, only while the panel shows.
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !HUDPresence.shared.open || still)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate * 60
                    ForEach(layout.links.indices, id: \.self) { index in
                        layout.links[index].path
                            .stroke(
                                HUD.primary,
                                style: StrokeStyle(lineWidth: 2, lineCap: .square, dash: [10, 140], dashPhase: -phase - Double(index) * 55)
                            )
                            .hudGlow()
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The main menu: slanted tabs on a hairline rail. The active tab lifts on a soft signal wash with a glowing rail.
struct HUDMenuTabs: View {
    let items: [String]
    @Binding var active: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                Button {
                    active = index
                } label: {
                    HStack(spacing: HUD.space2) {
                        Text(String(format: "%02d", index + 1)).hudType(.data).opacity(0.7)
                        Text(items[index]).hudType(.label)
                    }
                }
                .buttonStyle(HUDTabStyle(active: index == active))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityAddTraits(index == active ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct HUDTabStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        HUDTab(configuration: configuration, active: active)
    }
}

private struct HUDTab: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    var body: some View {
        let shape = HUDCut(kind: .tab, cut: 10)
        configuration.label
            .foregroundStyle(active || hovering ? HUD.ink : HUD.inkMuted)
            .padding(.leading, 10)
            .padding(.trailing, 18)
            .frame(height: 30)
            .background {
                if active {
                    shape.fill(HUD.primarySoft).mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
                } else if hovering {
                    shape.fill(HUD.glassSheen)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Rectangle().fill(active ? HUD.primary : HUD.glassEdge)
                    .frame(height: active ? 2 : 1)
                    .hudGlow(active: active)
                    .padding(.trailing, 10)
            }
            .overlay { shape.strokeBorder(HUD.focus, lineWidth: 2).opacity(focused ? 1 : 0) }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(HUD.easeStandard(HUD.durationFast), value: active)
    }
}

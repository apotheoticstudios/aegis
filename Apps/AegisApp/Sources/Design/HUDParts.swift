import SwiftUI

/// The ground behind everything: the void, with one soft nebula wash held well inside the frame. No grid, no pattern.
struct HUDGround: View {
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Rectangle().fill(HUD.void)
            .overlay {
                EllipticalGradient(
                    colors: [theme.color(.nebula).opacity(0.42), .clear], center: Self.centre, endRadiusFraction: 0.35
                )
                // The wash is an ellipse 50% of the width across and 42% of the height tall.
                .scaleEffect(x: 1, y: 0.84, anchor: Self.centre)
            }
    }

    private static let centre = UnitPoint(x: 0.5, y: 0.45)
}

/// The system's outlines. Nothing is rounded: corners are square or cut at 45°.
struct HUDCut: InsettableShape {
    enum Kind {
        /// The top right and bottom left cut: panels.
        case panel
        /// The top left and bottom right cut: tags, chips and other small controls.
        case tag
        /// A command plate: square top left, the right end cut on a full-height slant, a nick at the bottom left.
        case plate
        /// A menu tab: square, its right end cut on a full-height slant of `cut`.
        case tab
    }

    var kind: Kind
    var cut: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let edge = min(cut, box.width / 2, box.height / 2)
        let corners: [(CGFloat, CGFloat)] = switch kind {
        case .panel:
            [
                (box.minX, box.minY),
                (box.maxX - edge, box.minY),
                (box.maxX, box.minY + edge),
                (box.maxX, box.maxY),
                (box.minX + edge, box.maxY),
                (box.minX, box.maxY - edge),
            ]
        case .tag:
            [
                (box.minX + edge, box.minY),
                (box.maxX, box.minY),
                (box.maxX, box.maxY - edge),
                (box.maxX - edge, box.maxY),
                (box.minX, box.maxY),
                (box.minX, box.minY + edge),
            ]
        case .plate:
            [
                (box.minX, box.minY),
                (box.maxX, box.minY),
                (box.maxX - HUD.chamferSlant, box.maxY),
                (box.minX + edge, box.maxY),
                (box.minX, box.maxY - edge),
            ]
        case .tab:
            [(box.minX, box.minY), (box.maxX, box.minY), (box.maxX - cut, box.maxY), (box.minX, box.maxY)]
        }
        return Path { path in
            path.addLines(corners.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
        }
    }

    func inset(by amount: CGFloat) -> HUDCut {
        HUDCut(kind: kind, cut: cut, inset: inset + amount)
    }
}

/// Corner brackets, top left and bottom right, drawn inside the edge.
struct HUDBrackets: Shape {
    var arm: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: HUD.strokeFrame / 2, dy: HUD.strokeFrame / 2)
        var path = Path()
        path.addLines([
            CGPoint(x: box.minX, y: box.minY + arm), CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX + arm, y: box.minY),
        ])
        path.addLines([
            CGPoint(x: box.maxX - arm, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY - arm),
        ])
        return path
    }
}

extension View {
    /// A framed glass panel: thin glass over the void, a hairline edge, two cut corners and brackets on the other two.
    /// `tone` recolours the brackets: primary for the panel being acted on, critical when its content is critical.
    func hudPanel(tone: HUDColor = HUD.frame) -> some View {
        padding(HUD.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { HUDGlass(tone: tone) }
            .hudArrive(.open(0.42, traces: false))
    }

    /// The command line's box: a square hairline frame on solid surface, brighter on hover, primary with the focus
    /// ring while typing. Quiet, so the conversation above it carries the voice.
    func hudField(focused: Bool) -> some View {
        modifier(HUDField(focused: focused))
    }
}

// shortcut: no backdrop blur, as only the void and its soft wash sit behind panels, where a blur shows nothing; add a
// material if panels ever float over busy content (Aegis Mode's desktop).
struct HUDGlass: View {
    let tone: HUDColor
    var cut = HUD.chamferMd
    var arm: CGFloat = 16
    var sheen = 0.4
    @Environment(\.hudTheme) private var theme

    var body: some View {
        let shape = HUDCut(kind: .panel, cut: cut)
        shape.fill(HUD.surfaceGlass)
            .overlay {
                shape.fill(LinearGradient(
                    stops: [.init(color: theme.color(.glassSheen), location: 0), .init(color: .clear, location: sheen)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .overlay { shape.strokeBorder(HUD.glassEdge, lineWidth: HUD.strokeHair) }
            .overlay { HUDBrackets(arm: arm).stroke(tone, lineWidth: HUD.strokeFrame) }
    }
}

private struct HUDField: ViewModifier {
    let focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, HUD.space3)
            .frame(height: 34)
            .background(HUD.surface)
            .overlay(Rectangle().strokeBorder(focused ? HUD.primary : hovering ? HUD.inkMuted : HUD.frame, lineWidth: HUD.strokeHair))
            .overlay(Rectangle().inset(by: -4).strokeBorder(HUD.focus, lineWidth: HUD.strokeFrame).opacity(focused ? 1 : 0))
            .onHover { hovering = $0 }
            .animation(HUD.easeStandard(HUD.durationFast), value: focused)
            .animation(HUD.easeStandard(HUD.durationFast), value: hovering)
    }
}

/// A panel's title: a square pip in the panel's tone, then the title in label caps.
struct HUDHeading: View {
    let title: String
    var tone = HUD.frame

    var body: some View {
        HStack(spacing: HUD.space2) {
            Rectangle().fill(tone).frame(width: 6, height: 6)
            Text(title).hudType(.label).foregroundStyle(HUD.ink)
        }
    }
}

/// A status tag: a pip and one word from the status vocabulary, in the tone's colour. The word carries the meaning;
/// the colour backs it up. A live tag (the primary tone) breathes its pip.
struct HUDTag: View {
    let word: String
    var tone = HUD.inkMuted

    var body: some View {
        let shape = HUDCut(kind: .tag, cut: HUD.chamferSm)
        HStack(spacing: 6) {
            HUDLiveClock(running: tone == HUD.primary) { time in
                Rectangle().fill(tone).frame(width: 6, height: 6).opacity(time.map(HUDMotion.breathe) ?? 1)
            }
            Text(word).hudType(.label).lineLimit(1)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, HUD.space2)
        .frame(height: 22)
        .background(shape.fill(HUD.surface))
        .overlay(shape.strokeBorder(tone, lineWidth: HUD.strokeHair))
        .hudArrive(.flicker(0.28), after: 0.36)
    }
}

/// A small control (an inline action in a row): a tag-shaped plate with a hairline edge. Muted chips are the quieter
/// choices beside a main one (Junk, Mute, Cancel); a live chip is something happening now (the mic while listening).
struct HUDChipStyle: ButtonStyle {
    var muted = false
    var live = false

    func makeBody(configuration: Configuration) -> some View {
        HUDChip(configuration: configuration, muted: muted, live: live)
    }
}

private struct HUDChip: View {
    let configuration: ButtonStyleConfiguration
    let muted: Bool
    let live: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    var body: some View {
        let shape = HUDCut(kind: .tag, cut: HUD.chamferSm)
        configuration.label
            .hudType(.label)
            .lineLimit(1)
            .foregroundStyle(live ? HUD.primary : muted ? HUD.inkMuted : HUD.ink)
            .hudGlow(active: live)
            .padding(.horizontal, HUD.space2)
            .frame(height: 22)
            .background(shape.fill(configuration.isPressed ? HUD.primarySoft : hovering ? HUD.surfaceRaised : HUD.surface))
            .overlay(shape.strokeBorder(
                focused ? HUD.focus : live ? HUD.primary : muted ? HUD.line : HUD.frame,
                lineWidth: focused ? 2 : 1
            ))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(HUD.easeStandard(HUD.durationInstant), value: hovering)
    }
}

/// A command plate on its offset rail. Primary (filled, with a /// tail) once per view, for the command the view
/// exists for; ghost for everything else; critical, with a tail, for overrides. Leaves room below for the rail.
struct HUDPlateStyle: ButtonStyle {
    enum Kind {
        case primary, ghost, critical
    }

    var kind = Kind.ghost

    func makeBody(configuration: Configuration) -> some View {
        HUDPlate(configuration: configuration, kind: kind)
    }
}

private struct HUDPlate: View {
    let configuration: ButtonStyleConfiguration
    let kind: HUDPlateStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    var body: some View {
        let shape = HUDCut(kind: .plate, cut: HUD.chamferSm)
        let pressed = configuration.isPressed && enabled
        let edge = focused ? HUD.focus : kind == .primary ? HUD.primary : kind == .critical ? HUD.critical : HUD.frame
        let face = kind == .primary ? HUD.primary : pressed ? HUD.primarySoft : hovering ? HUD.surfaceRaised : HUD.surface
        HStack(spacing: HUD.space1) {
            configuration.label
            if kind != .ghost {
                Text("///").tracking(-0.5).opacity(0.7)
            }
        }
        .hudType(.label)
        .lineLimit(1)
        .foregroundStyle(kind == .primary ? HUD.onPrimary : kind == .critical ? HUD.critical : HUD.ink)
        .padding(.leading, HUD.space4)
        .padding(.trailing, HUD.space4 + HUD.chamferSlant)
        .frame(height: 36)
        .background(shape.fill(face))
        .overlay(shape.strokeBorder(edge, lineWidth: focused ? 2 : 1))
        .contentShape(shape)
        // Pressing slides the plate onto its rail.
        .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
        .padding(.bottom, 7)
        .background(alignment: .bottomTrailing) {
            HStack(alignment: .bottom, spacing: 2) {
                Rectangle().fill(edge).opacity(0.7).frame(height: 2).padding(.bottom, 1)
                Rectangle().fill(edge).frame(width: 4, height: 4)
            }
            .padding(.leading, 12)
            .padding(.trailing, HUD.chamferSlant)
        }
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(HUD.easeStandard(HUD.durationInstant), value: pressed)
        .animation(HUD.easeStandard(HUD.durationInstant), value: hovering)
        // Buttons wipe in last.
        .hudArrive(.wipe(0.36), after: 0.7)
    }
}

/// A section inside the shell (the design system's inset Panel): no glass of its own, its title and code over its
/// contents, divided from the section above by a hairline. `linked` has the shell draw a circuit link to its title.
/// In the build-on it arrives by its `index` down its column: its rule draws across, its head flickers on, then its
/// contents come in.
struct HUDSection<Content: View>: View {
    let title: String
    var code: String?
    var tone = HUD.frame
    /// The first section in a column has no rule above it.
    var first = false
    var linked = true
    var index = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                HUDHeading(title: title, tone: tone)
                Spacer(minLength: HUD.space2)
                if let code {
                    Text(code).hudType(.data).foregroundStyle(HUD.inkMuted).lineLimit(1)
                }
            }
            .modifier(HUDLinkIf(linked: linked))
            .hudArrive(.flicker(0.3), after: 0.12)
            VStack(alignment: .leading, spacing: HUD.space2) { content }
                .hudArrive(.fade(0.26, HUDMotion.enter), after: 0.2)
        }
        .padding(.top, first ? 0 : HUD.space4)
        .padding(.bottom, HUD.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !first {
                HUDRule()
            }
            HUDRuleTrace()
        }
        .environment(\.hudArrival.at, HUDMotion.section(index))
    }
}

private struct HUDLinkIf: ViewModifier {
    let linked: Bool

    func body(content: Content) -> some View {
        if linked {
            content.hudLink()
        } else {
            content
        }
    }
}

/// Human figures for the instruments: bytes in the largest unit that keeps them readable, fixed decimals.
enum HUDFormat {
    static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = max(0, value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let figure = unit == 0 || amount >= 100 ? String(Int(amount.rounded())) : String(format: "%.1f", amount)
        return figure + " " + units[unit] + (perSecond ? "/s" : "")
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// "6d 04:21", or "04:21" under a day.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds)) / 60
        let clock = String(format: "%02d:%02d", total / 60 % 24, total % 60)
        return total >= 1440 ? "\(total / 1440)d " + clock : clock
    }
}

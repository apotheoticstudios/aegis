import SwiftUI

/// The Project: Aegis design system's colour tokens (ADR-0029). Every theme defines every token, so a view names the
/// token and the theme decides the colour.
enum HUDToken: CaseIterable, Sendable {
    /// The ground behind everything, and the soft wash behind the centre instrument. Never text.
    case void, nebula
    /// Panel fills: solid for dense text, thin glass by default, raised for hover, selection and header strips.
    case surface, surfaceGlass, surfaceRaised
    /// A glass panel's hairline edge and the highlight across its top.
    case glassEdge, glassSheen
    /// Hairlines that mean nothing on their own, and edges that do (brackets, nodes, control borders).
    case line, frame
    /// Text and values, and labels, units and secondary text.
    case ink, inkMuted
    /// The live signal: live data and the one primary action. Soft fills go under it; on-primary goes on it.
    case primary, primarySoft, onPrimary
    /// The second identity hue.
    case accent, accentSoft, onAccent
    /// States, always with a status word.
    case ok, warn, critical
    /// Keyboard focus.
    case focus
}

/// The five themes. They share every token, so switching theme changes colour and nothing else. Arc is the default.
enum HUDTheme: String, CaseIterable, Sendable {
    case arc, automaton, phosphor, redline, matrix

    /// How strongly live things glow (glow-sm's alpha); Phosphor's lavender needs more.
    var glow: Double {
        self == .phosphor ? 0.6 : 0.45
    }

    func color(_ token: HUDToken) -> Color {
        let value = rgba(token)
        return Color(
            .sRGB, red: Self.channel(value, 24), green: Self.channel(value, 16), blue: Self.channel(value, 8),
            opacity: Self.channel(value, 0)
        )
    }

    /// RRGGBBAA, as the design system's tokens.json gives it; magenta if a theme ever lacks a token (tests forbid it).
    func rgba(_ token: HUDToken) -> UInt32 {
        Self.palettes[self]?[token] ?? 0xFF00_FFFF
    }

    static func channel(_ value: UInt32, _ shift: UInt32) -> Double {
        Double(value >> shift & 0xFF) / 255
    }

    private static let palettes: [HUDTheme: [HUDToken: UInt32]] = [
        .arc: [
            .void: 0x0207_0EFF, .nebula: 0x0F35_60FF, .surface: 0x0612_21FF, .surfaceGlass: 0x1C28_3366,
            .glassEdge: 0xFFFF_FF1F, .glassSheen: 0xFFFF_FF0F, .surfaceRaised: 0x0B22_36FF, .line: 0x1D4F_78FF,
            .frame: 0x3D8F_D6FF, .ink: 0xDCEF_FFFF, .inkMuted: 0x86B3_D9FF, .primary: 0x3FA9_FFFF,
            .primarySoft: 0x0D35_57FF, .onPrimary: 0x0212_20FF, .accent: 0xBFE6_FFFF, .accentSoft: 0x1232_4AFF,
            .onAccent: 0x0212_20FF, .ok: 0x5CF2_C4FF, .warn: 0xFFB5_47FF, .critical: 0xFF5C_72FF, .focus: 0xFFFF_FFFF,
        ],
        .automaton: [
            .void: 0x0606_0CFF, .nebula: 0x6E24_57FF, .surface: 0x0B10_16FF, .surfaceGlass: 0x1D25_2966,
            .glassEdge: 0xFFFF_FF1F, .glassSheen: 0xFFFF_FF0F, .surfaceRaised: 0x111C_24FF, .line: 0x2A4F_55FF,
            .frame: 0x5FBF_B6FF, .ink: 0xEEF7_F6FF, .inkMuted: 0x9BB8_B6FF, .primary: 0x62E3_D3FF,
            .primarySoft: 0x0F39_36FF, .onPrimary: 0x0314_13FF, .accent: 0xFF45_61FF, .accentSoft: 0x3A0D_18FF,
            .onAccent: 0x1203_0AFF, .ok: 0x8FF0_A8FF, .warn: 0xFFC0_4DFF, .critical: 0xFF7A_8CFF, .focus: 0xFFFF_FFFF,
        ],
        .phosphor: [
            .void: 0x0706_0DFF, .nebula: 0x2A1F_5CFF, .surface: 0x0D0B_1AFF, .surfaceGlass: 0x221F_2E66,
            .glassEdge: 0xFFFF_FF1F, .glassSheen: 0xFFFF_FF0F, .surfaceRaised: 0x1613_2BFF, .line: 0x3B35_70FF,
            .frame: 0x9D95_FFFF, .ink: 0xE4E0_FFFF, .inkMuted: 0xA69E_E6FF, .primary: 0xB3A8_FFFF,
            .primarySoft: 0x241E_52FF, .onPrimary: 0x0B08_20FF, .accent: 0xF3F0_FFFF, .accentSoft: 0x2B25_60FF,
            .onAccent: 0x0B08_20FF, .ok: 0x8FF5_C8FF, .warn: 0xFFC6_63FF, .critical: 0xFF7D_9AFF, .focus: 0xFFFF_FFFF,
        ],
        .redline: [
            .void: 0x0505_05FF, .nebula: 0x3A0B_0BFF, .surface: 0x0D0D_0EFF, .surfaceGlass: 0x1F1F_2166,
            .glassEdge: 0xFFFF_FF1F, .glassSheen: 0xFFFF_FF0F, .surfaceRaised: 0x1818_1AFF, .line: 0x3A3A_3EFF,
            .frame: 0x8A8A_90FF, .ink: 0xF2F2_F2FF, .inkMuted: 0xA3A3_A8FF, .primary: 0xFF45_45FF,
            .primarySoft: 0x3D0E_0EFF, .onPrimary: 0x1400_00FF, .accent: 0xF5F5_F5FF, .accentSoft: 0x2A2A_2EFF,
            .onAccent: 0x0A0A_0AFF, .ok: 0x9FE3_FFFF, .warn: 0xFFD8_4AFF, .critical: 0xFF9A_3CFF, .focus: 0xFFFF_FFFF,
        ],
        .matrix: [
            .void: 0x0107_03FF, .nebula: 0x0A3A_1CFF, .surface: 0x0310_0AFF, .surfaceGlass: 0x1626_1B66,
            .glassEdge: 0xFFFF_FF1F, .glassSheen: 0xFFFF_FF0F, .surfaceRaised: 0x0A22_14FF, .line: 0x1B4A_2AFF,
            .frame: 0x2EC4_5AFF, .ink: 0xD8FF_E2FF, .inkMuted: 0x78D0_8FFF, .primary: 0x00FF_41FF,
            .primarySoft: 0x0636_1AFF, .onPrimary: 0x0014_07FF, .accent: 0xEAFF_EEFF, .accentSoft: 0x1640_2AFF,
            .onAccent: 0x021A_0BFF, .ok: 0x8FE9_FFFF, .warn: 0xFFD4_47FF, .critical: 0xFF7A_45FF, .focus: 0xFFFF_FFFF,
        ],
    ]
}

extension EnvironmentValues {
    /// The interface's theme.
    @Entry var hudTheme: HUDTheme = .arc
}

/// A colour token as a style: it takes its colour from the theme in the environment.
struct HUDColor: ShapeStyle, Equatable {
    let token: HUDToken

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.hudTheme.color(token)
    }
}

/// The design tokens in one place: colours, space, edges and timing. Type styles are in HUDType.
enum HUD {
    static let void = HUDColor(token: .void)
    static let nebula = HUDColor(token: .nebula)
    static let surface = HUDColor(token: .surface)
    static let surfaceGlass = HUDColor(token: .surfaceGlass)
    static let surfaceRaised = HUDColor(token: .surfaceRaised)
    static let glassEdge = HUDColor(token: .glassEdge)
    static let glassSheen = HUDColor(token: .glassSheen)
    static let line = HUDColor(token: .line)
    static let frame = HUDColor(token: .frame)
    static let ink = HUDColor(token: .ink)
    static let inkMuted = HUDColor(token: .inkMuted)
    static let primary = HUDColor(token: .primary)
    static let primarySoft = HUDColor(token: .primarySoft)
    static let onPrimary = HUDColor(token: .onPrimary)
    static let accent = HUDColor(token: .accent)
    static let accentSoft = HUDColor(token: .accentSoft)
    static let onAccent = HUDColor(token: .onAccent)
    static let ok = HUDColor(token: .ok)
    static let warn = HUDColor(token: .warn)
    static let critical = HUDColor(token: .critical)
    static let focus = HUDColor(token: .focus)

    // Space: a 4-point grid. Panel padding is space4, the gutter between panels space6, the screen margin space8.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32
    static let space12: CGFloat = 48

    // Edges: nothing is rounded. Corners are square or cut at 45°; lines are a hairline for structure, 2 for meaning.
    static let chamferSm: CGFloat = 6
    static let chamferMd: CGFloat = 12
    static let chamferLg: CGFloat = 20
    static let chamferSlant: CGFloat = 14
    static let strokeHair: CGFloat = 1
    static let strokeFrame: CGFloat = 2

    // Timing: hover and press, then tabs, tags and focus. Everything decelerates into place; nothing bounces.
    static let durationInstant = 0.09
    static let durationFast = 0.16

    static func easeStandard(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0, 0, 1, duration: duration)
    }
}

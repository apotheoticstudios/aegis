import AppKit
import CoreText
import SwiftUI

/// One of the design system's type styles (ADR-0029). Text is set small on purpose: the panel reads like a terminal.
struct HUDType: Sendable {
    /// Xirod, about one em a letter: the one boot title or mode name on a screen.
    static let display = HUDType(xirod, size: 32, lineHeight: 40, tracking: 0.02, uppercase: true)
    /// Xirod: a heading above a group of panels, and the assistant's name.
    static let title = HUDType(xirod, size: 18, lineHeight: 24, tracking: 0.04, uppercase: true)
    /// Chakra Petch SemiBold, tracked wide: panel titles, field labels and button text.
    static let label = HUDType("ChakraPetch-SemiBold", size: 11, lineHeight: 14, tracking: 0.18, uppercase: true)
    /// Kode Mono: everything that is a sentence; strong for the lead line of an item.
    static let body = HUDType("KodeMono-Regular", size: 12, lineHeight: 18)
    static let bodyStrong = HUDType("KodeMono-SemiBold", size: 12, lineHeight: 18)
    /// Kode Mono: source and time under an item, helper text.
    static let caption = HUDType("KodeMono-Regular", size: 10, lineHeight: 14)
    /// Xirod: the hero figure of a screen.
    static let readoutXL = HUDType(xirod, size: 36, lineHeight: 44, tracking: 0.02)
    /// Share Tech Mono: values in readouts.
    static let readout = HUDType(shareTech, size: 20, lineHeight: 24)
    /// Share Tech Mono: every other number, code, time and log line.
    static let data = HUDType(shareTech, size: 11, lineHeight: 15, tracking: 0.02)
    /// Share Tech Mono: terminal rows and the command line.
    static let term = HUDType(shareTech, size: 12, lineHeight: 18)
    /// Share Tech Mono for character art: the line height equals the size so characters stack into a picture.
    static let ascii = HUDType(shareTech, size: 12, lineHeight: 12, tracking: 0.04)
    /// VT323, the stylised pixel voice: record titles, then record rows and terminal logs.
    static let pixelTitle = HUDType("VT323-Regular", size: 32, lineHeight: 32, tracking: 0.04, uppercase: true)
    static let terminal = HUDType("VT323-Regular", size: 22, lineHeight: 24, tracking: 0.02)

    private static let xirod = "Xirod-Regular"
    private static let shareTech = "ShareTechMono-Regular"

    /// The face's PostScript name. The bundled faces are always named this way: Chakra Petch SemiBold declares a
    /// family of its own, so a family name and a weight would find the regular face.
    let fontName: String
    let size: CGFloat
    /// Letter spacing in points.
    let tracking: CGFloat
    let uppercase: Bool
    /// What it takes to reach the style's line height from the face's own.
    let lineSpacing: CGFloat

    var font: Font {
        .custom(fontName, size: size)
    }

    private init(_ fontName: String, size: CGFloat, lineHeight: CGFloat, tracking: CGFloat = 0, uppercase: Bool = false) {
        _ = HUDFonts.registered
        self.fontName = fontName
        self.size = size
        self.tracking = tracking * size
        self.uppercase = uppercase
        let face = NSFont(name: fontName, size: size)
        lineSpacing = face.map { max(0, lineHeight - ($0.ascender - $0.descender + $0.leading)) } ?? 0
    }
}

/// The design system's fonts, bundled in Aegis.app (Resources/Fonts) and registered for Aegis's own process the first
/// time a type style is used. Nothing is installed on the Mac.
enum HUDFonts {
    static let registered: Bool = {
        let fonts = (Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Fonts") ?? [])
            .filter { ["ttf", "woff2"].contains($0.pathExtension) }
        // Every file is tried, so one that fails (already installed on the Mac, say) leaves the others registered.
        return !fonts.isEmpty && fonts.map { CTFontManagerRegisterFontsForURL($0 as CFURL, .process, nil) }.allSatisfy(\.self)
    }()
}

extension View {
    /// Sets text in one of the design system's type styles.
    func hudType(_ style: HUDType) -> some View {
        font(style.font).tracking(style.tracking).lineSpacing(style.lineSpacing).textCase(style.uppercase ? .uppercase : nil)
    }

    /// glow-sm, the soft light of a live value. Only live things glow: if everything glows, nothing does.
    func hudGlow(_ token: HUDToken = .primary, active: Bool = true) -> some View {
        modifier(HUDGlow(token: token, active: active))
    }

    /// glow-bloom, phosphor bloom on display type: one or two lines on a screen.
    func hudBloom() -> some View {
        modifier(HUDBloom())
    }
}

private struct HUDGlow: ViewModifier {
    let token: HUDToken
    let active: Bool
    @Environment(\.hudTheme) private var theme

    func body(content: Content) -> some View {
        content.shadow(color: theme.color(token).opacity(active ? theme.glow : 0), radius: 3)
    }
}

private struct HUDBloom: ViewModifier {
    @Environment(\.hudTheme) private var theme

    func body(content: Content) -> some View {
        content
            .shadow(color: theme.color(.ink), radius: 0.5)
            .shadow(color: theme.color(.primary).opacity(0.65), radius: 4)
    }
}

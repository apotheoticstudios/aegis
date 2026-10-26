import SwiftUI

/// The design system's faces at the sizes its controls use, beside the named type styles in HUDType.
enum HUDFace {
    /// Chakra Petch SemiBold, in caps with wide tracking: labels on controls and rows.
    static func caps(_ size: CGFloat) -> Font {
        _ = HUDFonts.registered
        return .custom("ChakraPetch-SemiBold", size: size)
    }

    /// Kode Mono: sentences.
    static func text(_ size: CGFloat) -> Font {
        _ = HUDFonts.registered
        return .custom("KodeMono-Regular", size: size)
    }

    /// Share Tech Mono: values, codes and notes.
    static func mono(_ size: CGFloat) -> Font {
        _ = HUDFonts.registered
        return .custom("ShareTechMono-Regular", size: size)
    }

    /// Xirod: titles and hero values.
    static func hero(_ size: CGFloat) -> Font {
        _ = HUDFonts.registered
        return .custom("Xirod-Regular", size: size)
    }
}

extension View {
    /// Caps in Chakra Petch at `size`, tracked by `tracking` em.
    func hudCaps(_ size: CGFloat, tracking: CGFloat = 0.14) -> some View {
        font(HUDFace.caps(size)).tracking(size * tracking).textCase(.uppercase)
    }
}

/// An on/off switch: a chamfered track with a slanted knob that slides right and glows when on, with ON or OFF in
/// mono beside it.
struct HUDToggle: View {
    @Binding var on: Bool
    let label: String
    var showState = true

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: HUD.space2) {
                ZStack(alignment: .leading) {
                    HUDCut(kind: .tag, cut: 4).fill(on ? HUD.primary : HUD.frame)
                    HUDCut(kind: .tag, cut: 4).inset(by: 1).fill(HUD.surface)
                    if on {
                        HUDHatch(gap: 4).fill(HUD.primarySoft).clipShape(HUDCut(kind: .tag, cut: 4).inset(by: 1))
                    }
                    Rectangle().fill(on ? HUD.primary : HUD.inkMuted)
                        .frame(width: 12, height: 8)
                        .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.445, d: 1, tx: 4, ty: 0))
                        .hudGlow(active: on)
                        .offset(x: on ? 18 : 2)
                }
                .frame(width: 36, height: 14)
                if showState {
                    Text(on ? "On" : "Off").font(HUDFace.mono(11)).tracking(0.88).textCase(.uppercase)
                        .foregroundStyle(on ? HUD.primary : HUD.inkMuted)
                }
            }
            .contentShape(Rectangle())
            .animation(HUD.easeStandard(HUD.durationFast), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Diagonal hatching at -60°, one point lines `gap` apart: the fill of a switched-on track and of warn zones.
struct HUDHatch: Shape {
    var gap: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var lines = Path()
        let rise = rect.height / tan(.pi / 3)
        var across = rect.minX - rise
        while across < rect.maxX {
            lines.move(to: CGPoint(x: across, y: rect.maxY))
            lines.addLine(to: CGPoint(x: across + rise, y: rect.minY))
            across += gap
        }
        return lines.strokedPath(StrokeStyle(lineWidth: 1)).intersection(Path(rect))
    }
}

/// One option of a segmented choice.
struct HUDOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var meta: String?
    var disabled = false

    var id: Value {
        value
    }
}

/// A short choice between two to five options as a row of joined plates: the chosen one fills with primary-soft and a
/// 2-point primary underline.
struct HUDSegmented<Value: Hashable>: View {
    let label: String
    let options: [HUDOption<Value>]
    @Binding var value: Value
    var small = false
    var locked = false

    var body: some View {
        HStack(spacing: -1) {
            ForEach(options) { option in
                let chosen = option.value == value
                Button { value = option.value } label: {
                    HStack(spacing: 6) {
                        Text(option.label).hudCaps(10)
                        if let meta = option.meta {
                            Text(meta).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
                        }
                    }
                    .foregroundStyle(chosen ? HUD.ink : HUD.inkMuted)
                    .padding(.horizontal, small ? HUD.space2 : HUD.space3)
                    .frame(height: small ? 24 : 28)
                    .background(chosen ? HUD.primarySoft : HUD.surface)
                    .overlay(alignment: .bottom) {
                        if chosen {
                            Rectangle().fill(HUD.primary).frame(height: 2)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(chosen ? HUD.primary : HUD.frame, lineWidth: 1))
                    .zIndex(chosen ? 1 : 0)
                    .opacity(option.disabled ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(option.disabled || locked)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The REC badge on a recommended answer.
struct HUDRec: View {
    var word = "Rec"

    var body: some View {
        Text(word).font(HUDFace.mono(9)).tracking(0.72).textCase(.uppercase)
            .foregroundStyle(HUD.accent)
            .padding(.horizontal, 4)
            .frame(height: 13)
            .overlay(Rectangle().strokeBorder(HUD.accent, lineWidth: 1))
    }
}

/// One setting: its label in caps (with a REC badge and a mono note), an optional hint under it, the control on the
/// right, and a hairline below.
struct HUDSettingRow<Control: View>: View {
    let label: String
    var hint: String?
    var meta: String?
    var recommended = false
    var compact = false
    var dim = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: HUD.space4) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                    Text(label).hudCaps(11).foregroundStyle(HUD.ink).lineLimit(1)
                    if recommended {
                        HUDRec()
                    }
                    if let meta {
                        Text(meta).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted).lineLimit(1)
                    }
                }
                if let hint {
                    Text(hint).font(HUDFace.text(11)).foregroundStyle(HUD.inkMuted).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: HUD.space2)
            HStack(spacing: HUD.space3) { control }
        }
        .padding(.vertical, compact ? 3 : 6)
        .frame(minHeight: compact ? 30 : 34)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
        .opacity(dim ? 0.5 : 1)
    }
}

/// A sub-heading inside a step: primary caps on the left, a mono note on the right.
struct HUDSubhead: View {
    let title: String
    var meta: String?
    /// The first in its column has no space above it.
    var first = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).hudCaps(10, tracking: 0.2).foregroundStyle(HUD.primary)
            Spacer(minLength: HUD.space2)
            if let meta {
                Text(meta).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
            }
        }
        .lineLimit(1)
        .padding(.top, first ? 0 : HUD.space4)
        .padding(.bottom, HUD.space1)
    }
}

/// A terminal record: a framed box open on its left, its title set into the top edge, and rows drawn as a tree
/// (├─ KEY value), a row's value in its tone, with an optional character meter.
struct HUDTermSection: View {
    struct Row: Hashable {
        let label: String
        let value: String
        var tone: HUDToken?
        var meter: Double?
    }

    var title: String?
    var tone = HUD.primary
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                    Text(index == rows.count - 1 ? "└─" : "├─").font(.system(size: 12, design: .monospaced)).foregroundStyle(HUD.frame)
                    Text(row.label.uppercased()).tracking(0.48).foregroundStyle(tone).frame(width: 66, alignment: .leading)
                    Text(row.value).foregroundStyle(row.tone.map { HUDColor(token: $0) } ?? HUD.ink)
                    if let meter = row.meter {
                        HUDCharMeter(value: meter, width: 10, tone: row.tone.map { HUDColor(token: $0) } ?? HUD.primary)
                    }
                }
                .font(HUDFace.mono(12))
                .lineLimit(1)
                .frame(height: 18)
            }
        }
        .padding(.leading, HUD.space2)
        .padding(.trailing, HUD.space3)
        .padding(.top, title == nil ? HUD.space1 : HUD.space2)
        .padding(.bottom, HUD.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(HUDTermFrame(gap: title == nil ? 0 : CGFloat(title?.count ?? 0) * 6.6 + 16).stroke(HUD.frame, lineWidth: 1))
        .overlay(alignment: .top) {
            if let title {
                Text(title).font(HUDFace.mono(12)).foregroundStyle(tone).padding(.horizontal, HUD.space2).offset(y: -9)
            }
        }
        .padding(.top, title == nil ? 0 : 6)
        .accessibilityElement(children: .combine)
    }
}

/// The record's frame: top, right and bottom edges, the left open, a gap in the top edge for the title.
private struct HUDTermFrame: Shape {
    let gap: CGFloat

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        let middle = box.midX
        path.move(to: CGPoint(x: middle - gap / 2, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        // One line at a time: addLines would start a new subpath and drop the edge after the title.
        path.move(to: CGPoint(x: middle + gap / 2, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        return path
    }
}

/// Keyboard keys as caps: each a square with a heavier bottom edge.
struct HUDKeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key).font(HUDFace.mono(11)).foregroundStyle(HUD.ink)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(HUD.surface)
                    .overlay(Rectangle().strokeBorder(HUD.frame, lineWidth: 1))
                    .overlay(alignment: .bottom) { Rectangle().fill(HUD.frame).frame(height: 2) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// One macOS permission: a status pip, its name and why, Open Settings until granted, and a status tag.
struct HUDPermissionRow: View {
    enum Status {
        case granted, needed, optional, denied
    }

    let name: String
    let why: String
    let status: Status
    var statusText: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: HUD.space3) {
            Rectangle().fill(status == .granted ? HUD.ok : status == .denied ? HUD.critical : HUDColor(token: .void))
                .frame(width: 6, height: 6)
                .overlay(Rectangle().strokeBorder(pipEdge, lineWidth: 1))
                .hudGlow(.ok, active: status == .granted)
                .frame(width: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).hudCaps(11).foregroundStyle(HUD.ink)
                Text(why).font(HUDFace.text(11)).foregroundStyle(HUD.inkMuted)
            }
            Spacer(minLength: HUD.space2)
            if status != .granted, let action {
                Button("Open Settings", action: action).buttonStyle(HUDPlateStyle(compact: true))
            }
            HUDTag(word: statusText ?? word, tone: tone)
        }
        .padding(.vertical, HUD.space2)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
    }

    private var word: String {
        switch status {
        case .granted: "Granted"
        case .needed: "Needed"
        case .optional: "Optional"
        case .denied: "Denied"
        }
    }

    private var tone: HUDColor {
        switch status {
        case .granted: HUD.ok
        case .needed: HUD.warn
        case .optional: HUD.inkMuted
        case .denied: HUD.critical
        }
    }

    private var pipEdge: HUDColor {
        switch status {
        case .granted: HUD.ok
        case .needed: HUD.warn
        case .optional: HUD.frame
        case .denied: HUD.critical
        }
    }
}

/// A terminal-style text field: a primary prompt (`name >`), the text, and a hint after a hairline.
struct HUDTermInput: View {
    let prompt: String
    @Binding var text: String
    var placeholder = ""
    var hint: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: HUD.space2) {
            Text(prompt).foregroundStyle(HUD.primary).fixedSize()
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(HUD.inkMuted))
                .textFieldStyle(.plain)
                .foregroundStyle(HUD.ink)
                .focused($focused)
            if let hint {
                Text(hint).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted).fixedSize()
                    .padding(.leading, HUD.space2)
                    .overlay(alignment: .leading) { Rectangle().fill(HUD.line).frame(width: 1) }
            }
        }
        .font(HUDFace.mono(12))
        .hudField(focused: focused)
    }
}

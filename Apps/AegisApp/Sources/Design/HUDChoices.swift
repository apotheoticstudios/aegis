import AppKit
import SwiftUI

/// A slider drawn as a hairline track of fine ticks lit up to the value, a slanted thumb, labelled marks and an
/// optional REC notch. Values above `warnFrom` sit in a hatched zone and turn the slider warn. `log` spreads small
/// values out (20 GB to 745 GB). As in the design, the Mac's own slider lies invisibly on top, so dragging, clicking
/// along it, the arrow keys (once clicked) and VoiceOver all work as they do everywhere else.
struct HUDRangeSlider<Display: View>: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var log = false
    var recommended: Int?
    var warnFrom: Int?
    var ticks = 60
    var marks: [(value: Int, label: String)] = []
    var ends: (String, String)?
    var hint: String?
    var showsValue = true
    var disabled = false
    /// A custom readout in place of the plain value, like Storage's big Xirod figure.
    @ViewBuilder var display: Display

    var body: some View {
        let tone = warnFrom.map { value > $0 } == true ? HUD.warn : HUD.primary
        VStack(alignment: .leading, spacing: HUD.space2) {
            if !label.isEmpty || showsValue {
                HStack(alignment: .lastTextBaseline, spacing: HUD.space4) {
                    Text(label).hudCaps(11).foregroundStyle(HUD.inkMuted)
                    Spacer(minLength: 0)
                    if showsValue {
                        if Display.self == EmptyView.self {
                            Text("\(value)").font(HUDFace.mono(12)).foregroundStyle(HUD.ink)
                        } else {
                            display
                        }
                    }
                }
            }
            GeometryReader { proxy in
                track(width: proxy.size.width, tone: tone)
            }
            .frame(height: 26)
            .overlay {
                // Its knob overhangs each end by half its width, so the native values line up with the drawn ticks.
                HUDNativeSlider(
                    share: Binding(get: { share(value) }, set: { value = amount(at: $0) }), label: label, readout: "\(value)",
                    enabled: !disabled
                )
                .padding(.horizontal, -HUDNativeSlider.knob / 2)
            }
            if !marks.isEmpty {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                            // A zero-width frame at the mark: the first label runs right of it, the last left, the rest centred.
                            Text(mark.label).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted).fixedSize()
                                .frame(width: 0, alignment: index == 0 ? .leading : index == marks.count - 1 ? .trailing : .center)
                                .offset(x: share(mark.value) * proxy.size.width)
                        }
                    }
                }
                .frame(height: 14)
            }
            if let ends {
                HStack {
                    Text(ends.0)
                    Spacer()
                    Text(ends.1)
                }
                .font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
            }
            if let hint {
                Text(hint).font(HUDFace.text(11)).foregroundStyle(HUD.inkMuted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(disabled ? 0.45 : 1)
    }

    private func track(width: CGFloat, tone: HUDColor) -> some View {
        let lit = share(value)
        return ZStack(alignment: .topLeading) {
            // The track: open brackets at each end, ticks rising from its foot, every fifth taller.
            HUDTicks(count: ticks, lit: lit, tone: tone.token)
                .frame(width: width, height: 10)
                .overlay(alignment: .leading) { Rectangle().fill(HUD.frame).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(HUD.frame).frame(width: 1) }
                .offset(y: 9)
            if let warnFrom, warnFrom < range.upperBound {
                let start = share(warnFrom) * width
                HUDHatch(gap: 5).fill(HUD.warn).opacity(0.35)
                    .frame(width: width - start, height: 16)
                    .offset(x: start, y: 6)
            }
            if let recommended {
                let at = share(recommended) * width
                Rectangle().fill(HUD.accent).frame(width: 1, height: 22).offset(x: at, y: 0)
                Text("Rec").font(HUDFace.mono(9)).tracking(0.72).textCase(.uppercase).foregroundStyle(HUD.accent)
                    .fixedSize().offset(x: at + 3, y: -12)
            }
            Rectangle().fill(tone)
                .frame(width: 8, height: 22)
                .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.287, d: 1, tx: 3.2, ty: 0))
                .hudGlow(tone.token)
                .offset(x: lit * width - 4, y: 3)
                .animation(HUD.easeStandard(HUD.durationInstant), value: value)
        }
        .frame(width: width, height: 26, alignment: .topLeading)
    }

    /// Where `amount` sits along the track, 0 to 1.
    private func share(_ amount: Int) -> Double {
        let low = Double(range.lowerBound)
        let high = Double(max(range.upperBound, range.lowerBound + 1))
        let clamped = min(max(Double(amount), low), high)
        return log && low > 0 ? Foundation.log(clamped / low) / Foundation.log(high / low) : (clamped - low) / (high - low)
    }

    /// The amount at a share of the track, on the step.
    private func amount(at share: Double) -> Int {
        let fraction = min(max(share, 0), 1)
        let low = Double(range.lowerBound)
        let high = Double(range.upperBound)
        let raw = log && low > 0 ? low * pow(high / low, fraction) : low + fraction * (high - low)
        return min(max(Int((raw / Double(step)).rounded()) * step, range.lowerBound), range.upperBound)
    }
}

/// The Mac's own slider, all but invisible over the drawn one: AppKit tracks the pointer and the arrow keys and tells
/// VoiceOver the value, and the drawing shows where it stands.
private struct HUDNativeSlider: NSViewRepresentable {
    /// The knob's width, which overhangs the drawn track by half at each end.
    @MainActor static let knob = NSSlider().knobThickness

    @Binding var share: Double
    let label: String
    let readout: String
    let enabled: Bool

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: share, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.moved(_:)))
        slider.isContinuous = true
        slider.alphaValue = 0.011
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.share = $share
        if abs(slider.doubleValue - share) > 0.002 {
            slider.doubleValue = share
        }
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(readout)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(share: $share)
    }

    @MainActor final class Coordinator: NSObject {
        var share: Binding<Double>

        init(share: Binding<Double>) {
            self.share = share
        }

        @objc func moved(_ slider: NSSlider) {
            share.wrappedValue = slider.doubleValue
        }
    }
}

/// The slider's ticks: every fifth taller, those up to the value lit and glowing.
private struct HUDTicks: View {
    let count: Int
    let lit: Double
    let tone: HUDToken
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Canvas { context, size in
            var on = Path()
            var off = Path()
            for tick in 0 ... count {
                let share = Double(tick) / Double(max(count, 1))
                let height: CGFloat = tick.isMultiple(of: 5) ? 10 : 6
                let bar = CGRect(x: share * (size.width - 1), y: size.height - height, width: 1, height: height)
                if share <= lit + 1e-6 {
                    on.addRect(bar)
                } else {
                    off.addRect(bar)
                }
            }
            context.fill(off, with: .color(theme.color(.line)))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: theme.color(tone), radius: 1.5))
                layer.fill(on, with: .color(theme.color(tone)))
            }
        }
    }
}

extension HUDRangeSlider where Display == EmptyView {
    init(
        label: String, value: Binding<Int>, range: ClosedRange<Int>, ticks: Int = 60, ends: (String, String)? = nil,
        showsValue: Bool = true, disabled: Bool = false
    ) {
        self.init(
            label: label, value: value, range: range, ticks: ticks, ends: ends, showsValue: showsValue, disabled: disabled
        ) { EmptyView() }
    }
}

/// A selectable tile for a choice that needs a sentence: a square mark, the title in caps with an optional badge and
/// a mono note, the description and an optional extra line. Chosen, its edge turns primary, the mark fills, corner
/// brackets appear and a soft wash comes up. `multiple` makes it a checkbox.
struct HUDChoiceCard<Art: View>: View {
    let title: String
    var description: String?
    let selected: Bool
    var multiple = false
    var badge: String?
    var meta: String?
    var extra: String?
    var compact = false
    var disabled = false
    let action: () -> Void
    @ViewBuilder var art: Art
    @State private var hovering = false
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: HUD.space3) {
                Rectangle().fill(.clear).frame(width: 10, height: 10)
                    .overlay(Rectangle().strokeBorder(selected ? HUD.primary : HUD.frame, lineWidth: 1))
                    .overlay {
                        if selected {
                            Rectangle().fill(HUD.primary).padding(multiple ? 1 : 2).hudGlow()
                        }
                    }
                    .padding(.top, 3)
                    .frame(width: 12)
                if Art.self != EmptyView.self {
                    art
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                        Text(title).hudCaps(11).foregroundStyle(HUD.ink).lineLimit(1)
                        if let badge {
                            HUDRec(word: badge)
                        }
                        Spacer(minLength: 0)
                        if let meta {
                            Text(meta).font(HUDFace.mono(11)).foregroundStyle(HUD.inkMuted).lineLimit(1)
                        }
                    }
                    if let description {
                        Text(description).font(HUDFace.text(11)).foregroundStyle(HUD.inkMuted).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let extra {
                        Text(extra).font(HUDFace.mono(11)).foregroundStyle(HUD.ink).padding(.top, HUD.space1)
                    }
                }
            }
            .padding(.vertical, compact ? HUD.space2 : HUD.space3)
            .padding(.horizontal, compact ? HUD.space3 : HUD.space4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: theme.color(selected ? .primarySoft : .glassSheen), location: 0),
                        .init(color: .clear, location: selected ? 0.7 : 0.45),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .background(HUD.surfaceGlass)
            }
            .overlay(Rectangle().strokeBorder(selected ? HUD.primary : hovering ? HUD.frame : HUD.glassEdge, lineWidth: 1))
            .overlay {
                if selected {
                    HUDBrackets(arm: 8).stroke(HUD.primary, lineWidth: 1).padding(-1)
                }
            }
            .contentShape(Rectangle())
            .opacity(disabled ? 0.45 : 1)
            .animation(HUD.easeStandard(HUD.durationFast), value: selected)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension HUDChoiceCard where Art == EmptyView {
    init(
        title: String, description: String? = nil, selected: Bool, multiple: Bool = false, badge: String? = nil,
        meta: String? = nil, extra: String? = nil, compact: Bool = false, disabled: Bool = false, action: @escaping () -> Void
    ) {
        self.init(
            title: title, description: description, selected: selected, multiple: multiple, badge: badge, meta: meta,
            extra: extra, compact: compact, disabled: disabled, action: action
        ) { EmptyView() }
    }
}

/// The reactor with its caption (the design's ReactorCore): the label, a hero value and the state underneath.
struct HUDReactorCore: View {
    let mode: ReactorView.Mode
    var size: CGFloat = 240
    let label: String
    var value: String?

    var body: some View {
        VStack(spacing: HUD.space2) {
            ReactorView(mode: mode, size: size)
            HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                Text(label).hudCaps(11, tracking: 0.18).foregroundStyle(HUD.inkMuted)
                if let value {
                    Text(value).font(HUDFace.hero(22)).tracking(0.44).foregroundStyle(HUD.ink).hudGlow()
                }
                Text(state).hudCaps(11, tracking: 0.18).foregroundStyle(HUD.primary)
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var state: String {
        switch mode {
        case .idle: "Idle"
        case .thinking: "Think"
        case .listening: "Listen"
        case .speaking: "Speak"
        }
    }
}

import SwiftUI

/// The compact voice bar over the frontmost app. The host centres it below the menu bar and owns its lifetime;
/// `typed` is the share of the answer spoken so far, not a second typing clock. Escape dismisses a presentation.
@MainActor
struct HUDVoiceOverlay: View {
    /// The voice turn's phase: hearing the owner, preparing a reply, or speaking it.
    enum State: String, CaseIterable, Sendable {
        case listening, thinking, answering

        fileprivate var mode: ReactorView.Mode {
            switch self {
            case .listening: .listening
            case .thinking: .thinking
            case .answering: .speaking
            }
        }

        fileprivate var word: String {
            switch self {
            case .listening: "Listening"
            case .thinking: "Thinking"
            case .answering: "Speaking"
            }
        }

        /// Every state is live: the design's VOICE_STATE gives each the live tone.
        fileprivate var tone: HUDColor {
            HUD.primary
        }
    }

    let state: State
    let transcript: String
    let answer: String
    var meta: String?
    var name = "aegis"
    /// Clamped to 0...1 and applied to whole characters; Reduce Motion always shows the complete answer.
    var typed = 1.0
    @SwiftUI.State private var opened = Date()
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center, spacing: HUD.space4) {
            ReactorView(mode: state.mode, size: 76, still: still)
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                head
                if !transcript.isEmpty {
                    line("you", text: transcript, caret: state == .listening)
                }
                if state == .thinking {
                    line(name, text: "thinking…", assistant: true, muted: true, caret: true)
                }
                if state == .answering, !answer.isEmpty {
                    line(name, text: shownAnswer, assistant: true, caret: true)
                }
                if let meta, !meta.isEmpty {
                    Text(meta).hudType(.caption).font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 64)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: HUD.space3, leading: HUD.space3, bottom: HUD.space3, trailing: HUD.space4))
        .frame(width: 520)
        .background { HUDGlass(tone: HUD.frame, cut: HUD.chamferSm) }
        .clipShape(HUDCut(kind: .panel, cut: HUD.chamferSm))
        // The bar has its own arrival, independent of the desktop's build-on.
        .environment(\.hudArrival, HUDArrival())
        .modifier(VoiceArrival(opened: opened))
        .accessibilityElement(children: .contain)
        .onExitCommand { dismiss() }
    }

    private var shownAnswer: String {
        guard !still else { return answer }
        let share = typed.isNaN ? 0 : min(max(typed, 0), 1)
        return String(answer.prefix(Int((Double(answer.count) * share).rounded(.down))))
    }

    private var head: some View {
        HStack(spacing: HUD.space3) {
            HUDTag(word: state.word, tone: state.tone)
            if state == .listening {
                HUDAsciiArt(shape: .wave, cols: 16, rows: 2, detail: 2, grit: 0.1, tone: HUD.primary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // The shared key caps are 22 pt; the voice bar uses the design's compact 18 pt key.
                Text("esc").font(HUDFace.mono(10)).foregroundStyle(HUD.ink)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(HUD.surface)
                    .overlay(Rectangle().strokeBorder(HUD.frame, lineWidth: HUD.strokeHair))
                    .overlay(alignment: .bottom) { Rectangle().fill(HUD.frame).frame(height: HUD.strokeFrame) }
                Text("dismiss").font(HUDFace.mono(10)).foregroundStyle(HUD.inkMuted)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Escape to dismiss")
        }
    }

    private func line(_ who: String, text: String, assistant: Bool = false, muted: Bool = false, caret: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
            Text(who + " >").font(HUDFace.mono(11))
                .foregroundStyle(assistant ? HUD.primary : HUD.inkMuted)
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(text).foregroundStyle(muted ? HUD.inkMuted : HUD.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if caret {
                    HUDLiveClock(every: 0.5) { time in
                        Rectangle().fill(HUD.primary).frame(width: 6, height: 12)
                            .opacity(time.map { HUDMotion.blink($0) ? 1 : 0 } ?? 1)
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hudType(.body)
    }
}

private struct VoiceArrival: ViewModifier {
    let opened: Date
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        let frames = HUDMotion.frames(start: still ? nil : opened, at: 0, until: 0.42, fps: 30, now: Date())
        TimelineView(.explicit(frames)) { context in
            let progress = still ? 1 : HUDMotion.progress(context.date.timeIntervalSince(opened), 0, 0.42)
            content.clipShape(HUDOpening(progress: progress))
        }
    }
}

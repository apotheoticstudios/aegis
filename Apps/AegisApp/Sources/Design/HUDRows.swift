import SwiftUI

/// One item in a feed: a source line (the app in label caps, then where and when), a lead line and Aegis's reading of
/// it, with a square pip that fills and glows while it waits on the owner. With an action, the head opens and closes
/// the detail below it.
struct HUDNotification<Detail: View>: View {
    let source: String
    var device: String?
    var time: String?
    let title: String
    var text: String?
    var tone = HUD.frame
    var unread = false
    var tag: HUDTag?
    var action: (() -> Void)?
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let action {
                Button(action: action) { head.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                head
            }
            detail
        }
        .padding(.vertical, HUD.space2)
        .padding(.leading, HUD.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(unread ? tone : HUD.void)
                .frame(width: 5, height: 5)
                .overlay(Rectangle().strokeBorder(tone, lineWidth: 1))
                .hudGlow(tone.token, active: unread)
                .padding(.top, HUD.space2 + 4)
        }
        .overlay(alignment: .bottom) { HUDRule() }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
                Text(source).hudType(.label).foregroundStyle(HUD.ink)
                if let device {
                    Text(device).hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
                Spacer(minLength: HUD.space2)
                if let time {
                    Text(time).hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
            }
            .lineLimit(1)
            Text(title).hudType(.bodyStrong).foregroundStyle(HUD.ink).fixedSize(horizontal: false, vertical: true)
            if let text {
                Text(text).foregroundStyle(HUD.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            if let tag {
                tag.padding(.top, HUD.space2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HUDNotification where Detail == EmptyView {
    init(
        source: String, device: String? = nil, time: String? = nil, title: String, text: String? = nil, tone: HUDColor = HUD.frame,
        unread: Bool = false, tag: HUDTag? = nil
    ) {
        self.init(source: source, device: device, time: time, title: title, text: text, tone: tone, unread: unread, tag: tag) {
            EmptyView()
        }
    }
}

/// One line of the activity log, in fixed columns: time, source, a level word and the message.
struct HUDLogRow: View {
    enum Level: String {
        /// Something collected or noted.
        case info
        /// Something went right.
        case ok
        /// Aegis did something.
        case act
        /// Something was remembered or changed in memory.
        case mem
        case warn
        case err
    }

    let time: String
    let source: String
    let level: Level
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
            Text(time).foregroundStyle(HUD.inkMuted).frame(width: 62, alignment: .leading)
            Text(source.uppercased()).tracking(0.44).foregroundStyle(HUD.ink).frame(width: 76, alignment: .leading)
            Text(level.rawValue.uppercased()).foregroundStyle(tone).frame(width: 38, alignment: .leading)
            Text(message).hudType(.body).foregroundStyle(HUD.ink).frame(maxWidth: .infinity, alignment: .leading)
        }
        .hudType(.data)
        .lineLimit(1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tone: HUDColor {
        switch level {
        case .info: HUD.inkMuted
        case .ok: HUD.ok
        case .act: HUD.primary
        case .mem: HUD.accent
        case .warn: HUD.warn
        case .err: HUD.critical
        }
    }
}

/// One turn of the conversation: a right-aligned `you >` or `aegis >` prompt, then the text. The owner's lines sit
/// muted so Aegis's answers lead; Aegis's prompt glows in the signal colour, with a block caret while it writes.
struct HUDChatLine<Meta: View>: View {
    let who: String
    let text: String
    var aegis = false
    var writing = false
    var failed = false
    @ViewBuilder var meta: Meta

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HUD.space3) {
            Text(who + " >").hudType(.data)
                .foregroundStyle(aegis ? HUD.primary : HUD.inkMuted)
                .hudGlow(active: aegis)
                .frame(width: 64, alignment: .trailing)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(text)
                        .foregroundStyle(failed ? HUD.warn : aegis ? HUD.ink : HUD.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if writing {
                        Rectangle().fill(HUD.primary).frame(width: 6, height: 12).hudGlow().accessibilityHidden(true)
                    }
                }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

extension HUDChatLine where Meta == EmptyView {
    init(who: String, text: String, aegis: Bool = false, writing: Bool = false, failed: Bool = false) {
        self.init(who: who, text: text, aegis: aegis, writing: writing, failed: failed) { EmptyView() }
    }
}

/// A command phrase under the input: a hairline-bordered mono label that asks it when clicked.
struct HUDCommandChip: View {
    let phrase: String
    let action: () -> Void

    var body: some View {
        Button(phrase, action: action)
            .buttonStyle(.plain)
            .hudType(.caption)
            .foregroundStyle(HUD.inkMuted)
            .padding(.horizontal, HUD.space2)
            .padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(HUD.glassEdge, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

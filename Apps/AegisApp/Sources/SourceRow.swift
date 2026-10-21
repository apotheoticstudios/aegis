import AegisKit
import AppKit
import SwiftUI

/// One message an item is based on: where it came from, who, when, a short excerpt, and Open.
/// Open only shows the original in its own app; it never sends or changes anything.
struct SourceRow: View {
    let event: Event
    let accent: Color
    /// "Junk" for a sender who isn't a contact (#175); nil hides the button.
    var onJunk: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(SourcePresentation.heading(event))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let onJunk {
                    Button("Junk", action: onJunk)
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        .help("Treat this sender's messages as junk from now on")
                }
                if let link = EventLink.link(for: event) {
                    Button("Open") { SourcePresentation.open(link) }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Rectangle().strokeBorder(accent.opacity(0.7), lineWidth: 1))
                }
            }
            Text(SourcePresentation.excerpt(event))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .overlay(Rectangle().strokeBorder(accent.opacity(0.25), lineWidth: 1))
    }
}

/// How a source reads, and how it opens. Pure apart from `open`.
enum SourcePresentation {
    /// "MAIL · jordan@example.com · Thu 07:12"
    static func heading(_ event: Event, now: Date = Date(), calendar: Calendar = .current) -> String {
        let source = switch event.source {
        case .email: "MAIL"
        case .imessage: "IMESSAGE"
        case .sms: "SMS"
        case .notification: appName(event.appID) ?? "NOTIFICATION"
        }
        let who = SenderDisplay.label(event) ?? "unknown"
        return [source, who, when(event.eventTime, now: now, calendar: calendar)].joined(separator: " · ")
    }

    /// The subject or title, then the text, on one line, at most 240 characters.
    static func excerpt(_ event: Event) -> String {
        let parts = [event.title, event.body.isEmpty ? nil : event.body].compactMap(\.self)
        let line = parts.joined(separator: " — ").split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 240 ? String(line.prefix(239)) + "…" : (line.isEmpty ? "(no text)" : line)
    }

    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE d MMM HH:mm"
        return format.string(from: date)
    }

    static func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "").uppercased()
    }

    /// Shows the original in its app: Mail at that email, Messages at that conversation, or the app that
    /// posted the notification. User-initiated only.
    @MainActor static func open(_ link: EventLink) {
        switch link {
        case let .url(url):
            NSWorkspace.shared.open(url)
        case let .app(bundleID):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}

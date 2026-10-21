import Foundation

/// Identity and conversation boundaries supplied by readers, never inferred from body text.
enum EventEvidence {
    static func exposesIdentity(_ text: String) -> Bool {
        text.range(of: #"\b(?:sender_id|conversation)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func thread(_ event: Event) -> String? {
        guard let id = event.threadID, !id.isEmpty else { return nil }
        let source = switch event.source {
        case .sms, .imessage: "messages"
        case .email: "email"
        case .notification: "notification:" + (event.appID ?? "unknown")
        }
        return SHA256.hex(Array((source + "\0" + id).utf8))
    }

    static func metadata(_ event: Event) -> String {
        let conversation = thread(event).map { String($0.prefix(16)) } ?? "unknown"
        let person = event.senderContact.map { String(SHA256.hex(Array($0.id.utf8)).prefix(16)) } ?? "unknown"
        return " · conversation=\(conversation) · sender_id=\(person) · "
            + (SenderDisplay.isOutgoing(event) ? "outgoing" : "incoming")
    }

    static func attendees(_ item: CalendarOccurrence) -> String {
        let names = (item.attendees ?? []).prefix(20).map {
            $0.isOwner ? "you" : ($0.name ?? $0.email ?? "unnamed invitee")
        }
        return " · status=\(item.status.rawValue) · listed invitees (attendance unconfirmed): "
            + (names.isEmpty ? "unknown" : jsonString(names.joined(separator: ", ")))
    }
}

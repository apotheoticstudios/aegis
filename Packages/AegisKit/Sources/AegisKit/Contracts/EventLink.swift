import Foundation

/// How the panel opens an event's original in its own app, when the user clicks Open.
///
/// Only fixed schemes are built, from fields the readers took from the stores (a Message-ID, a sender
/// handle, a posting app's bundle ID), never from message text. Opening shows the original; it never sends,
/// replies or changes anything, and nothing in collected content can trigger it.
public enum EventLink: Equatable, Sendable {
    /// Mail's `message:` link to one email, or Messages' `sms:` link to a conversation.
    case url(URL)
    /// The app that posted a notification.
    case app(bundleID: String)

    public static func link(for event: Event) -> EventLink? {
        switch event.source {
        case .email:
            return mail(messageID: event.sourceRecordID)
        case .imessage, .sms:
            // A group chat's ID has ";+;" (one-to-one chats have ";-;"). Messages has no public link to a
            // group, and a link to the sender would open the wrong (one-to-one) conversation (#153).
            if event.threadID?.contains(";+;") == true {
                return .app(bundleID: "com.apple.MobileSMS")
            }
            let handle = SenderDisplay.isOutgoing(event) ? event.recipients.first : event.senderHandle
            return handle.flatMap(messages(handle:))
        case .notification:
            guard let app = event.appID, isBundleID(app) else {
                return nil
            }
            return .app(bundleID: app)
        }
    }

    /// `message://%3C…%3E`: Mail opens the email with this Message-ID.
    static func mail(messageID: String) -> EventLink? {
        var id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<"), id.hasSuffix(">") {
            id = String(id.dropFirst().dropLast())
        }
        guard !id.isEmpty, id.count <= 998, id.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "message://%3C" + encoded + "%3E")
        else {
            return nil
        }
        return .url(url)
    }

    /// `sms:` + a phone number or email address: Messages opens that conversation.
    static func messages(handle: String) -> EventLink? {
        let compact = handle.filter { !$0.isWhitespace && !"-()".contains($0) }
        let phone = compact.hasPrefix("+") ? compact.dropFirst() : Substring(compact)
        let isPhone = !phone.isEmpty && phone.count <= 20 && phone.allSatisfy(\.isASCII) && phone.allSatisfy(\.isNumber)
        let isEmail = compact.count <= 254 && compact.split(separator: "@").count == 2
            && compact.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !"<>\"'`;&?#%/\\:".unicodeScalars.contains($0) }
        guard isPhone || isEmail, let encoded = compact.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "sms:" + encoded)
        else {
            return nil
        }
        return .url(url)
    }

    static func isBundleID(_ text: String) -> Bool {
        text.count <= 255 && text.contains(".")
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-.".unicodeScalars.contains($0) }
    }

    /// RFC 3986 unreserved characters plus `@` and `+`, which Mail's and Messages' links keep as they are.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@+")
}

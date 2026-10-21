import Foundation

/// Why Aegis treated a message as junk (#167).
public enum FilterReason: String, Codable, Sendable, CaseIterable {
    /// The owner marked this sender junk (#175, additive), regardless of automatic noise rules.
    case markedJunk = "marked_junk"
    /// Bulk or marketing email from someone who isn't a contact (List-Unsubscribe and similar headers).
    case bulk
    /// A one-time or verification code.
    case code
    /// A promotion or sale.
    case promotion
    /// A routine app status notice ("backup complete").
    case appNotice = "app_notice"
    /// A routine delivery notice.
    case delivery
    /// An automated prompt (surveys, booking confirmations, renewals) from a no-reply sender.
    case automated
}

/// One sender whose messages Aegis treated as junk in the last day (#167).
public struct FilteredSender: Codable, Sendable, Hashable {
    /// What to show: the sender's name or handle, or the app for notifications.
    public var sender: String
    /// What "Not junk" trusts: the sender's handle, or the app's bundle ID for notifications.
    public var handle: String
    /// The reason for the newest of their filtered messages.
    public var reason: FilterReason
    public var count: Int
    /// The newest one's subject or text, one line, at most 120 characters.
    public var latest: String
    /// Their filtered messages, newest first (at most 10).
    public var eventIDs: [String]

    public init(sender: String, handle: String, reason: FilterReason, count: Int, latest: String, eventIDs: [String]) {
        self.sender = sender
        self.handle = handle
        self.reason = reason
        self.count = count
        self.latest = latest
        self.eventIDs = eventIDs
    }

    enum CodingKeys: String, CodingKey {
        case sender, handle, reason, count, latest
        case eventIDs = "event_ids"
    }
}

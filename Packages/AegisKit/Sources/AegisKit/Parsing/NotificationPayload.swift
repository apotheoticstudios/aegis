import Foundation

/// Failures while decoding a Notification Center property-list payload.
public enum NotificationPayloadError: Error, Sendable, Equatable {
    /// Foundation could not deserialize the data as a property list.
    case invalidPropertyList
    /// The property list's root object is not a dictionary.
    case notDictionary
}

/// Text content extracted from a Notification Center record's property list.
public struct NotificationPayload: Sendable, Equatable {
    /// The request's title, or nil when missing or not a string.
    public let title: String?
    /// The request's subtitle, or nil when missing or not a string.
    public let subtitle: String?
    /// The request's body, or an empty string when missing or not a string.
    public let body: String

    /// Decodes a property-list dictionary, treating a missing or non-dictionary `req` as empty.
    /// Supports binary plists and other Foundation plist formats, as the Python reader does.
    public static func decode(_ data: Data) throws(NotificationPayloadError) -> NotificationPayload {
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw .invalidPropertyList
        }
        guard let payload = value as? [String: Any] else {
            throw .notDictionary
        }
        let request = payload["req"] as? [String: Any] ?? [:]
        return NotificationPayload(
            title: request["titl"] as? String,
            subtitle: request["subt"] as? String,
            body: request["body"] as? String ?? ""
        )
    }
}

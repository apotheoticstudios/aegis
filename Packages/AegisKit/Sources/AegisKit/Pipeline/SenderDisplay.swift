import Foundation

/// Speaker labels from source identity fields only; collected title and body are never consulted.
public enum SenderDisplay {
    /// v0.2 direction is authoritative. Only a v0.1 event may use the legacy owner sentinel.
    public static func isOutgoing(_ event: Event) -> Bool {
        event.direction == .outgoing || (event.schemaVersion == "0.1" && event.sender == "me")
    }

    /// A contact name, ambiguous raw handle, unresolved source identity, or notification app identity.
    /// The contract does not retain a match count; a caller with that evidence may supply it separately.
    public static func label(_ event: Event, ambiguousCount: Int? = nil) -> String? {
        if isOutgoing(event) {
            return "you"
        }
        if let contact = event.senderContact {
            return contact.name
        }
        if let handle = event.senderHandle, !handle.isEmpty {
            if event.flags.contains(.ambiguousSender) {
                let matches = ambiguousCount.flatMap { $0 > 1 ? "\($0) contacts" : nil } ?? "several contacts"
                return handle + " (matches \(matches))"
            }
            return handle
        }
        if let sender = event.sender, !sender.isEmpty, sender != "me" {
            return sender
        }
        return event.source == .notification ? event.appID : nil
    }
}

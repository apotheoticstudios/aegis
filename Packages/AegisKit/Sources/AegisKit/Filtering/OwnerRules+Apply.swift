import Foundation

public extension OwnerRules {
    /// Why an owner rule hides an event. Automatic noise rules are applied separately.
    enum Hide: Sendable, Hashable {
        case junk, muted, keyword
    }

    /// Incoming junk is keyed exactly like Filtered; muting uses the brief's person and group identities.
    /// Outgoing group messages belong to the group too; a member's direct chats remain separate.
    func hide(_ event: Event, contacts: [String: Event.ContactRef]) -> Hide? {
        let handle = event.senderHandle ?? (event.source == .notification ? event.appID : nil)
        if !SenderDisplay.isOutgoing(event), let handle, junk.contains(Filtered.trustKey(handle)) {
            return .junk
        }
        if let person = BriefLayout.person(of: [event], contacts: contacts), muted[person.id] != nil {
            return .muted
        }
        if !SenderDisplay.isOutgoing(event), event.source == .email, let handle = event.senderHandle,
           muted["handle:" + handle] != nil
        {
            return .muted
        }
        if !isVIP(event, contacts: contacts), matchesKeyword(event, effect: .hide) {
            return .keyword
        }
        return nil
    }

    /// Keeps visible events in their original order, resolving notification contact identities once.
    func visible(_ events: [Event]) -> [Event] {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contacts = BriefLayout.contactIDs(byID)
        return events.filter { hide($0, contacts: contacts) == nil }
    }

    /// Marks a sender junk and removes "Not junk". False means invalid input and leaves rules unchanged.
    @discardableResult
    mutating func markJunk(_ handle: String) -> Bool {
        let key = Filtered.trustKey(handle)
        guard !key.isEmpty, key.unicodeScalars.count <= 320 else { return false }
        junk.insert(key)
        trusted.remove(key)
        return true
    }

    /// Marks a sender "Not junk" and removes junk. False means invalid input and leaves rules unchanged.
    @discardableResult
    mutating func notJunk(_ handle: String) -> Bool {
        let key = Filtered.trustKey(handle)
        guard !key.isEmpty, key.unicodeScalars.count <= 320 else { return false }
        trusted.insert(key)
        junk.remove(key)
        return true
    }

    /// Mutes a person or group, storing a trimmed name of 1 to 120 Unicode scalars.
    /// False means invalid input and leaves rules unchanged.
    @discardableResult
    mutating func mute(_ id: String, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validPersonID(id), !name.isEmpty, name.unicodeScalars.count <= 120 else { return false }
        muted[id] = name
        return true
    }

    /// Removes a mute (including an already absent one). False means an invalid person ID.
    @discardableResult
    mutating func unmute(_ id: String) -> Bool {
        guard Self.validPersonID(id) else { return false }
        muted.removeValue(forKey: id)
        return true
    }

    internal static func validPersonID(_ id: String) -> Bool {
        ["contact:", "group:", "handle:"].contains { prefix in
            id.hasPrefix(prefix) && !id.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

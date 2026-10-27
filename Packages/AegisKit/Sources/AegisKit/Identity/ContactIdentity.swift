import Foundation

/// A portable copy of a contact card; the platform adapter supplies these values without exposing its store.
public struct ContactSnapshot: Sendable, Equatable, Codable {
    /// Stable contact identifier. Empty identifiers are excluded from the index.
    public var id: String
    /// Display name; a blank name falls back to the queried handle.
    public var displayName: String
    /// Raw phone numbers, short codes, or brand sender strings.
    public var phones: [String]
    /// Raw email addresses; plus-addresses remain distinct.
    public var emails: [String]
    /// True for the owner's own card (Contacts' "Me" card, #218): its handles are the owner's, never a sender's.
    public var isMe: Bool?

    /// Creates a value snapshot, with no access to Contacts or other personal data stores.
    public init(id: String, displayName: String, phones: [String] = [], emails: [String] = [], isMe: Bool? = nil) {
        self.isMe = isMe
        self.id = id
        self.displayName = displayName
        self.phones = phones
        self.emails = emails
    }
}

/// The result of resolving only a sender's handle.
public enum Resolution: Sendable, Equatable {
    /// No contact has this handle.
    case none
    /// Exactly one distinct contact has this handle.
    case match(Event.ContactRef)
    /// Multiple distinct contact identifiers have this handle; no name is selected.
    case ambiguous(count: Int)
}

/// An immutable index built in O(total handles), with expected O(1) dictionary lookups after normalization.
/// Repeated handles, snapshots with the same contact ID, or duplicate cards with the same name do not create ambiguity.
public struct ContactIndex: Sendable {
    private var contactsByHandle: [String: [String: Event.ContactRef]] = [:]
    /// The owner's own handles (#218): from the Me card and the addresses their sent mail comes from.
    private var ownerKeys: Set<String> = []
    var preservesUnmatchedContacts = false
    private let defaultRegion: String

    /// Indexes snapshots. AU national numbers gain country code 61; other regions require explicit
    /// international numbers. Short codes and brand senders match exactly after outer trimming and `tel:` removal.
    /// The first snapshot for an ID supplies its name if duplicate snapshots share a handle.
    public init(_ contacts: [ContactSnapshot], defaultRegion: String = "AU") {
        self.defaultRegion = defaultRegion.uppercased()
        for contact in contacts where !contact.id.isEmpty {
            if contact.isMe == true {
                ownerKeys.formUnion((contact.phones + contact.emails).compactMap(key(for:)))
                continue
            }
            let reference = Event.ContactRef(id: contact.id, name: contact.displayName)
            for handle in contact.phones + contact.emails {
                guard let key = key(for: handle), contactsByHandle[key]?[contact.id] == nil else { continue }
                contactsByHandle[key, default: [:]][contact.id] = reference
            }
        }
    }

    /// Every contact's name (#223): what a cloud hand-off must never carry.
    public var names: Set<String> {
        Set(contactsByHandle.values.flatMap { $0.values.map(\.name) }.filter { !$0.isEmpty })
    }

    /// Resolves a raw phone, email, short code, or brand sender, never a display name or message text.
    /// Normalization costs O(handle length); the index lookup and ambiguity count are expected O(1).
    public func resolve(handle: String) -> Resolution {
        guard let key = key(for: handle), let matches = contactsByHandle[key] else { return .none }
        // Cards with the same number and the same name are one person saved twice (owner's request, ADR-0021); the
        // first ID keeps rules and history together. Different names sharing a number are never guessed.
        let names = Set(matches.values.map { MemoryText.normalise($0.name) }.filter { !$0.isEmpty })
        if matches.count > 1, names.count != 1 {
            return .ambiguous(count: matches.count)
        }
        guard var contact = matches.values.sorted(by: { $0.id < $1.id })
            .first(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? matches.values.first
        else { return .none }
        if contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contact.name = handle
        }
        return .match(contact)
    }

    /// Matches full names before first names; an ambiguous name never selects an arbitrary person.
    func people(mentionedIn question: String) -> (ids: Set<String>, ambiguous: Bool) {
        let words = " " + AskQuery.words(question).joined(separator: " ") + " "
        let all = contactsByHandle.values.flatMap(\.values)
        func contains(_ name: String) -> Bool {
            let key = AskQuery.words(name).joined(separator: " ")
            return !key.isEmpty && words.contains(" " + key + " ")
        }
        let full = all.filter { contains($0.name) }
        let selected = full.isEmpty ? all.filter { contains(String($0.name.split(separator: " ").first ?? "")) } : full
        let grouped = Dictionary(grouping: selected) {
            full.isEmpty ? AskQuery.words($0.name).first ?? "" : AskQuery.words($0.name).joined(separator: " ")
        }
        return (Set(selected.map(\.id)), grouped.values.contains { Set($0.map(\.id)).count > 1 })
    }

    /// Owner corrections override only the asserted handle, without mutating the platform Contacts store.
    mutating func apply(_ aliases: [SenderAlias]) {
        guard !aliases.isEmpty else { return }
        var byName: [String: [String: Event.ContactRef]] = [:]
        for contacts in contactsByHandle.values {
            for contact in contacts.values {
                byName[MemoryText.normalise(contact.name), default: [:]][contact.id] = contact
            }
        }
        for alias in aliases {
            let known = byName[MemoryText.normalise(alias.name)] ?? [:]
            let contact = known.count == 1 ? known.values.first : nil
            let reference = contact ?? Event.ContactRef(id: "owner:" + SHA256.hex(Array(alias.key.utf8)), name: alias.name)
            contactsByHandle[alias.key] = [reference.id: reference]
        }
    }

    /// True when the handle is the owner's own (#218).
    public func isOwner(handle: String) -> Bool {
        key(for: handle).map(ownerKeys.contains) ?? false
    }

    /// Adds one of the owner's handles, such as an address their sent mail comes from (#218).
    public mutating func addOwner(handle: String) {
        if let key = key(for: handle) {
            ownerKeys.insert(key)
        }
    }

    func key(for handle: String) -> String? {
        var text = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("mailto:") {
            text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.contains("@") {
            return "email:" + text.lowercased()
        }
        if text.lowercased().hasPrefix("tel:") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        let compact = text.filter { !$0.isWhitespace && !"-.()[]".contains($0) }
        let digits = compact.hasPrefix("+") ? String(compact.dropFirst()) : compact
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            return "exact:" + text
        }
        if compact.hasPrefix("+") {
            return (7 ... 15).contains(digits.count) && !digits.hasPrefix("0") ? "phone:" + digits : "exact:" + text
        }
        if defaultRegion == "AU" {
            if digits.count == 10, digits.hasPrefix("0"), "23478".contains(digits.dropFirst().prefix(1)) {
                return "phone:61" + digits.dropFirst()
            }
            if digits.count == 11, digits.hasPrefix("61") {
                return "phone:" + digits
            }
        }
        // Bare international numbers have their country code already. Short/local numbers stay exact.
        if (11 ... 15).contains(digits.count), !digits.hasPrefix("0") {
            return "phone:" + digits
        }
        return "exact:" + text
    }
}

/// Resolves sender handles without reading title or body. Outgoing events and events with no handle
/// remain unchanged. Other events replace stale contact/ambiguity results and preserve all other fields.
public func resolveSenders(_ events: [Event], index: ContactIndex) -> [Event] {
    events.map { event in
        guard event.direction != .outgoing, let handle = event.senderHandle else { return event }
        var resolved = event
        // The owner's own address or number (mail between their own accounts, #218): theirs, not someone else's.
        if index.isOwner(handle: handle) {
            resolved.direction = .outgoing
            resolved.senderContact = nil
            resolved.flags.removeAll { $0 == .ambiguousSender }
            return resolved
        }
        resolved.senderContact = nil
        resolved.flags.removeAll { $0 == .ambiguousSender }
        switch index.resolve(handle: handle) {
        case .none:
            if index.preservesUnmatchedContacts {
                return event
            }
        case let .match(contact): resolved.senderContact = contact
        case .ambiguous: resolved.flags.append(.ambiguousSender)
        }
        return resolved
    }
}

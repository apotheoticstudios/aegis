import Foundation

/// A local habit-based proposal; it never changes an owner's priority or visibility rules (#278).
public struct RuleSuggestion: Codable, Sendable, Hashable {
    /// The existing owner rule that accepting this proposal would apply.
    public enum Kind: String, Codable, Sendable, Hashable {
        /// Prioritise someone the owner repeatedly answers quickly.
        case vip
        /// Hide an unknown sender the owner never replies to.
        case mute
    }

    /// The rule to offer, awaiting an explicit owner decision.
    public var kind: Kind
    /// The same contact:/group:/handle: identity used by `Brief.Person` and owner rules.
    public var personID: String
    /// A display name derived only from source identity fields, never message bodies.
    public var name: String
    /// What the records establish; opening/read state is not available and is never inferred.
    public var reason: String
    /// Distinct quick reply occasions for VIP, or ignored incoming records for mute.
    public var evidenceCount: Int

    /// Creates a proposal without applying it.
    public init(kind: Kind, personID: String, name: String, reason: String, evidenceCount: Int) {
        self.kind = kind
        self.personID = personID
        self.name = name
        self.reason = reason
        self.evidenceCount = evidenceCount
    }
}

public extension OwnerRules {
    /// A proposal ignored by the owner until its expiry; this is not an active visibility/priority rule.
    struct SuggestionDismissal: Codable, Sendable, Hashable {
        /// The dismissed contact:/group:/handle: identity.
        public var personID: String
        /// Dismissing one rule kind does not dismiss the other kind.
        public var kind: RuleSuggestion.Kind
        /// The proposal may return at this time (30 calendar days after dismissal).
        public var expiresAt: Date

        /// Creates a persisted dismissal with a caller-supplied expiry.
        public init(personID: String, kind: RuleSuggestion.Kind, expiresAt: Date) {
            self.personID = personID
            self.kind = kind
            self.expiresAt = expiresAt
        }
    }
}

/// Deterministic, on-demand proposals from a fortnight of records, with no model or actions.
public enum RuleSuggestions {
    /// Uses the last 14 calendar days through `now`. One outgoing record counts at most once per person.
    /// Replies match a source-scoped thread or a normalized recipient identity; group replies stay in their group.
    /// At most three proposals, ordered by evidence count, then kind and person ID. Dismissals expire at their boundary.
    public static func compute(events: [Event], rules: OwnerRules, now: Date, calendar: Calendar) -> [RuleSuggestion] {
        guard let start = calendar.date(byAdding: .day, value: -14, to: now) else { return [] }
        var seen = Set<String>()
        let recent = events.filter { $0.eventTime >= start && $0.eventTime <= now }
            .sorted { ($0.eventTime, $0.id) < ($1.eventTime, $1.id) }.filter { seen.insert($0.id).inserted }
        var names: [String: Event.ContactRef] = [:]
        for event in recent {
            if let contact = event.senderContact {
                names[contact.id] = contact
            }
        }
        let contacts = BriefLayout.contactIDs(Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
            .mapValues { names[$0.id] ?? $0 }
        let outgoing = recent.filter { SenderDisplay.isOutgoing($0) && $0.source != .notification }
        let ownerHandles = Set(outgoing.compactMap(\.senderHandle).map(BriefLayout.handleKey))
        let ownerContacts = Set(outgoing.compactMap { $0.senderContact?.id })
        var replies: [String: [Event]] = [:]
        for event in outgoing {
            if let thread = threadKey(event) {
                replies[thread, default: []].append(event)
            }
            // A reply in a group must not imply a separate direct relationship with every member.
            guard !isGroup(event) else { continue }
            for handle in event.recipients {
                for key in identityKeys(handle: handle, contacts: contacts) {
                    replies[key, default: []].append(event)
                }
            }
        }
        var incoming: [String: [Event]] = [:]
        for event in recent {
            guard !SenderDisplay.isOutgoing(event), event.direction != .unknown,
                  event.source != .notification || MessagesApp.contains(event.appID)
                  || event.appID.map({ !$0.hasPrefix("com.apple.") }) == true,
                  event.senderHandle.map({ !ownerHandles.contains(BriefLayout.handleKey($0)) }) ?? true,
                  event.senderContact.map({ !ownerContacts.contains($0.id) }) ?? true,
                  let person = person(event, contacts: contacts), OwnerRules.validPersonID(person.id),
                  person.id.unicodeScalars.count <= 320
            else { continue }
            incoming[person.id, default: []].append(event)
        }
        let proposals = incoming.compactMap { id, received in
            proposal(id: id, received: received, contacts: contacts, replies: replies, rules: rules, now: now)
        }
        return Array(proposals.sorted {
            if $0.evidenceCount != $1.evidenceCount {
                return $0.evidenceCount > $1.evidenceCount
            }
            return ($0.kind.rawValue, $0.personID) < ($1.kind.rawValue, $1.personID)
        }.prefix(3))
    }

    private static func proposal(
        id: String, received: [Event], contacts: [String: Event.ContactRef], replies: [String: [Event]], rules: OwnerRules, now: Date
    ) -> RuleSuggestion? {
        guard rules.vip[id] == nil, rules.muted[id] == nil,
              !received.contains(where: { rules.hide($0, contacts: contacts) != nil }),
              let latest = received.last, let person = person(latest, contacts: contacts)
        else { return nil }
        var quickReplies = Set<String>()
        var positions: [String: Int] = [:]
        var everReplied = false
        for event in received {
            var keys = threadKey(event).map { [$0] } ?? []
            if !isGroup(event), let handle = event.senderHandle {
                keys += identityKeys(handle: handle, contacts: contacts)
            }
            if !isGroup(event) {
                keys.append(id)
            }
            var first: Event?
            for key in Set(keys) {
                let candidates = replies[key] ?? []
                everReplied = everReplied || !candidates.isEmpty
                var position = positions[key] ?? 0
                while position < candidates.count,
                      candidates[position].eventTime <= event.eventTime || quickReplies.contains(candidates[position].id)
                {
                    position += 1
                }
                positions[key] = position
                if position < candidates.count {
                    let reply = candidates[position]
                    if first.map({ (reply.eventTime, reply.id) < ($0.eventTime, $0.id) }) ?? true {
                        first = reply
                    }
                }
            }
            if let first, first.eventTime.timeIntervalSince(event.eventTime) <= 15 * 60 {
                quickReplies.insert(first.id)
            }
        }
        let kind: RuleSuggestion.Kind
        let count: Int
        if quickReplies.count >= 5 {
            kind = .vip; count = quickReplies.count
        } else if received.count >= 8, !everReplied,
                  !received
                  .contains(where: { $0.senderContact != nil || $0.senderHandle.flatMap { contacts[BriefLayout.handleKey($0)] } != nil
                  }),
                  !id.hasPrefix("contact:")
        {
            kind = .mute; count = received.count
        } else {
            return nil
        }
        guard !rules.suggestionDismissals.contains(where: { $0.personID == id && $0.kind == kind && $0.expiresAt > now })
        else { return nil }
        let label = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = (label.isEmpty ? latest.senderHandle ?? "Unknown sender" : label).unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? Unicode.Scalar(UInt8(32)) : $0
        }
        let line = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(String.UnicodeScalarView(line.unicodeScalars.prefix(120)))
        let reason = kind == .vip
            ? "You replied to \(name) within 15 minutes \(count) times this fortnight"
            : "You haven’t replied to \(name)’s \(count) messages this fortnight"
        return RuleSuggestion(kind: kind, personID: id, name: name, reason: reason, evidenceCount: count)
    }

    private static func isGroup(_ event: Event) -> Bool {
        (event.source == .imessage || event.source == .sms) && event.threadID?.contains(";+;") == true
    }

    private static func threadKey(_ event: Event) -> String? {
        guard let thread = event.threadID, !thread.isEmpty else { return nil }
        return (event.source == .email ? "mail-thread:" : "messages-thread:") + thread
    }

    private static func identityKeys(handle: String, contacts: [String: Event.ContactRef]) -> [String] {
        let normalized = BriefLayout.handleKey(handle.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalized.isEmpty else { return [] }
        return ["handle:" + normalized] + (contacts[normalized].map { ["contact:" + $0.id] } ?? [])
    }

    private static func person(_ event: Event, contacts: [String: Event.ContactRef]) -> Brief.Person? {
        if !isGroup(event), let handle = event.senderHandle, let contact = contacts[BriefLayout.handleKey(handle)] {
            return Brief.Person(id: "contact:" + contact.id, name: contact.name)
        }
        if let person = BriefLayout.person(of: [event], contacts: contacts) {
            return person
        }
        // Unknown email senders still have a stable address that the owner can explicitly mute.
        guard event.source == .email, let handle = event.senderHandle, !handle.isEmpty else { return nil }
        return Brief.Person(id: "handle:" + handle, name: SenderDisplay.label(event) ?? handle)
    }
}

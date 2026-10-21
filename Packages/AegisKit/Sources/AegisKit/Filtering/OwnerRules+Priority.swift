import Foundation

public extension OwnerRules {
    /// True for an incoming message belonging to a VIP person or group chat.
    func isVIP(_ event: Event, contacts: [String: Event.ContactRef] = [:]) -> Bool {
        guard !SenderDisplay.isOutgoing(event) else { return false }
        if let person = BriefLayout.person(of: [event], contacts: contacts) {
            return vip[person.id] != nil
        }
        return event.source == .email && event.senderHandle.map { vip["handle:" + $0] != nil } == true
    }

    /// Adds a VIP, validating the identity and trimmed name exactly like a mute.
    @discardableResult
    mutating func prioritise(_ id: String, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validPersonID(id), !name.isEmpty, name.unicodeScalars.count <= 120 else { return false }
        vip[id] = name
        return true
    }

    /// Removes a VIP, including an already absent one. Invalid IDs leave rules unchanged.
    @discardableResult
    mutating func unprioritise(_ id: String) -> Bool {
        guard Self.validPersonID(id) else { return false }
        vip.removeValue(forKey: id)
        return true
    }

    /// Adds or replaces a phrase's effect. At most 50 distinct case-insensitive phrases are stored.
    /// Invalid input leaves rules unchanged; an existing phrase can be updated at the limit.
    @discardableResult
    mutating func addKeyword(_ phrase: String, effect: KeywordRule.Effect) -> Bool {
        guard let phrase = Self.validKeyword(phrase) else { return false }
        let index = keywords.firstIndex { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }
        guard index != nil || keywords.count < 50 else { return false }
        let rule = KeywordRule(phrase: phrase, effect: effect)
        if let index {
            keywords[index] = rule
        } else {
            keywords.append(rule)
        }
        return true
    }

    /// Removes a case-insensitive phrase, including an already absent one.
    @discardableResult
    mutating func removeKeyword(_ phrase: String) -> Bool {
        guard let phrase = Self.validKeyword(phrase) else { return false }
        keywords.removeAll { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }
        return true
    }

    /// Whether an incoming event matches an owner keyword of the given effect.
    func matchesKeyword(_ event: Event, effect: KeywordRule.Effect) -> Bool {
        keywords.contains { $0.effect == effect && $0.matches(event) }
    }
}

extension OwnerRules {
    static func validKeyword(_ phrase: String) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2 ... 60).contains(trimmed.unicodeScalars.count) ? trimmed : nil
    }
}

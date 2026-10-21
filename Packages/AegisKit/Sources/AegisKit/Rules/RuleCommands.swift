import Foundation

/// Fixed refusals for a recognized rule whose target cannot safely be selected.
public enum RuleCommandRefusal: String, Error, Sendable {
    case noMatch = "no_match"
    case ambiguous
}

/// Deterministic interpretation of the owner's panel input only. Never parse collected content here.
public enum RuleCommands {
    /// A recognized action and its lower-cased target phrase, before identity resolution.
    public struct ParsedCommand: Sendable, Hashable {
        public var action: RuleProposal.Action
        public var target: String

        public init(action: RuleProposal.Action, target: String) {
            self.action = action
            self.target = target
        }
    }

    /// One short sentence; larger or unclear input remains an Ask question.
    public static let maxScalars = 200

    private static let patterns: [(RuleProposal.Action, String)] = [
        (.unvip, #"(.+?)\s+(?:isn't|isn’t|is\s+not)\s+a\s+vip"#),
        (.unvip, #"stop\s+prioriti[sz]ing\s+(.+)"#),
        (.vip, #"always\s+show\s+(.+)"#),
        (.vip, #"(.+?)\s+is\s+a\s+vip"#),
        (.vip, #"make\s+(.+?)\s+important"#),
        (.keywordUrgent, #"anything\s+about\s+(.+?)\s+is\s+urgent"#),
        (.keywordUrgent, #"mark\s+messages\s+mentioning\s+(.+?)\s+as\s+urgent"#),
        (.keywordHide, #"hide\s+anything\s+about\s+(.+)"#),
        (.keywordHide, #"ignore\s+messages\s+mentioning\s+(.+)"#),
        (.removeKeyword, #"forget\s+the\s+(.+?)\s+rule"#),
        (.removeKeyword, #"remove\s+the\s+keyword\s+(.+)"#),
        (.notJunk, #"(.+?)\s+(?:isn't|isn’t|aren't|aren’t|(?:is|are)\s+not)\s+(?:junk|spam)"#),
        (.notJunk, #"not\s+(?:junk|spam)\s+(.+)"#),
        (.junk, #"(.+?)\s+(?:is|are)\s+(?:junk|spam)"#),
        (.junk, #"(?:junk|spam)\s+(.+)"#),
        (.junk, #"mark\s+(.+?)\s+as\s+(?:junk|spam)"#),
        (.unmute, #"(?:unmute|unignore)\s+(.+)"#),
        (.unmute, #"show\s+(.+?)\s+again"#),
        (.mute, #"(?:mute|ignore|silence|hide)\s+(.+)"#),
        (.mute, #"stop\s+showing\s+(?:me\s+)?(.+)"#),
    ]

    /// Anchored English patterns only; questions and multiple sentences never become proposals.
    public static func parse(_ text: String) -> ParsedCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSentence(trimmed) else { return nil }
        var sentence = trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if sentence.hasSuffix(".") || sentence.hasSuffix("!") {
            sentence.removeLast()
        }
        for (action, pattern) in patterns {
            guard let phrase = capture(pattern, in: sentence) else { continue }
            let keyword = isKeyword(action)
            let target = keyword ? phrase.trimmingCharacters(in: .whitespacesAndNewlines) : targetPhrase(phrase)
            guard !keyword || OwnerRules.validKeyword(target) != nil else { return nil }
            guard !target.isEmpty else { return nil }
            return ParsedCommand(action: action, target: target)
        }
        return nil
    }

    private static func validSentence(_ text: String) -> Bool {
        guard !text.isEmpty, text.unicodeScalars.count <= maxScalars,
              !text.contains("?"), !text.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { return false }
        let questions = #"^(?:who|what|when|where|why|how|did|does|do|is|are|was|were|can|could|would|should)\b"#
        let sentences = #"[.!;]\s+\S|[.!]{2}|\s+(?:and|or|then)\s+"#
            + #"(?:mute|unmute|ignore|unignore|silence|hide|junk|spam|mark|show|stop|always|make|forget|remove)\b"#
        return text.range(of: questions, options: [.regularExpression, .caseInsensitive]) == nil
            && text.range(of: sentences, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + #")\z"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func targetPhrase(_ phrase: String) -> String {
        var target = phrase.replacingOccurrences(
            of: #"^(?:the\s+)?(?:messages|emails|texts)\s+from\s+"#, with: "", options: .regularExpression
        )
        target = target.replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
        target = target.replacingOccurrences(of: #"^(?:group\s+chat|group|chat)\s+"#, with: "", options: .regularExpression)
        target = target.replacingOccurrences(of: #"\s+(?:group\s+chat|group|chat)\z"#, with: "", options: .regularExpression)
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["the", "chat", "group", "group chat"].contains(target) ? "" : target
    }

    /// Keyword proposals need only the owner's typed phrase, never collected events.
    public static func isKeyword(_ action: RuleProposal.Action) -> Bool {
        action == .keywordUrgent || action == .keywordHide || action == .removeKeyword
    }

    /// Resolve against all named, merged events in the caller's 30-day snapshot, including hidden events.
    /// This returns a proposal only; applying it requires a separate, explicit owner request.
    public static func resolve(
        _ command: ParsedCommand, events: [Event], rules: OwnerRules
    ) -> Result<RuleProposal, RuleCommandRefusal> {
        switch command.action {
        case .mute, .vip:
            return select(command, candidates: people(events))
        case .unmute:
            let candidates = rules.muted.map { Candidate(target: $0.key, name: $0.value, aliases: [$0.key, $0.value]) }
            return select(command, candidates: candidates)
        case .unvip:
            let candidates = rules.vip.map { Candidate(target: $0.key, name: $0.value, aliases: [$0.key, $0.value]) }
            return select(command, candidates: candidates)
        case .keywordUrgent, .keywordHide, .removeKeyword:
            guard let phrase = OwnerRules.validKeyword(command.target) else { return .failure(.noMatch) }
            return .success(proposal(command.action, target: phrase, name: phrase))
        case .junk, .notJunk:
            return sender(command, events: events)
        }
    }
}

private extension RuleCommands {
    struct Candidate {
        var target: String
        var name: String
        var aliases: Set<String>
        var contact = false
    }

    static func people(_ events: [Event]) -> [Candidate] {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contacts = BriefLayout.contactIDs(byID)
        var candidates: [String: Candidate] = [:]
        for event in newestFirst(events) {
            guard let person = BriefLayout.person(of: [event], contacts: contacts) else { continue }
            var candidate = candidates[person.id] ?? Candidate(
                target: person.id, name: person.name, aliases: [], contact: person.id.hasPrefix("contact:")
            )
            candidate.aliases.formUnion([person.id, person.name])
            if !person.id.hasPrefix("group:"), let handle = event.senderHandle {
                candidate.aliases.insert(handle)
            }
            candidates[person.id] = candidate
        }
        return Array(candidates.values)
    }

    static func sender(_ command: ParsedCommand, events: [Event]) -> Result<RuleProposal, RuleCommandRefusal> {
        let contacts = contactSenders(events)
        if isHandle(command.target) {
            let key = Filtered.trustKey(command.target)
            let knownContact = contacts.contains { candidate in
                candidate.aliases.contains { BriefLayout.handleKey($0) == BriefLayout.handleKey(key) }
            }
            guard !knownContact else { return .failure(.noMatch) }
            return .success(proposal(command.action, target: key, name: key))
        }
        var candidates: [String: Candidate] = [:]
        for event in newestFirst(events) where !SenderDisplay.isOutgoing(event) {
            guard event.senderContact == nil,
                  let handle = event.senderHandle ?? (event.source == .notification ? event.appID : nil)
            else { continue }
            let key = Filtered.trustKey(handle)
            guard !key.isEmpty else { continue }
            let label = event.source == .notification ? (event.title ?? event.appID) : SenderDisplay.label(event)
            var candidate = candidates[key] ?? Candidate(target: key, name: label ?? handle, aliases: [])
            candidate.aliases.formUnion([handle, label, event.source == .notification ? event.appID : nil].compactMap(\.self))
            candidates[key] = candidate
        }
        return select(command, candidates: Array(candidates.values) + contacts)
    }

    /// A group member is still a contact, even when all their events belong to a group identity.
    static func contactSenders(_ events: [Event]) -> [Candidate] {
        var contacts = Dictionary(uniqueKeysWithValues: people(events).filter(\.contact).map { ($0.target, $0) })
        for event in newestFirst(events) {
            guard let contact = event.senderContact else { continue }
            let id = "contact:" + contact.id
            var candidate = contacts[id] ?? Candidate(target: id, name: contact.name, aliases: [], contact: true)
            candidate.aliases.formUnion([id, contact.name, event.senderHandle].compactMap(\.self))
            contacts[id] = candidate
        }
        return Array(contacts.values)
    }

    static func isHandle(_ phrase: String) -> Bool {
        if phrase.contains("@"), !phrase.contains(where: \.isWhitespace) {
            return true
        }
        let phone = phrase.filter { !"+-.() ".contains($0) }
        if !phone.isEmpty, phone.allSatisfy(\.isNumber) {
            return true
        }
        return phrase.range(of: #"^[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    static func select(_ command: ParsedCommand, candidates: [Candidate]) -> Result<RuleProposal, RuleCommandRefusal> {
        let phrase = command.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = candidates.filter { $0.aliases.contains { Filtered.trustKey($0) == phrase } }
        let matches = exact.isEmpty ? candidates.filter { candidate in
            candidate.aliases.contains { wordPrefix(phrase, in: Filtered.trustKey($0)) }
        } : exact
        guard !matches.isEmpty else { return .failure(.noMatch) }
        if command.action == .junk || command.action == .notJunk, matches.contains(where: \.contact) {
            return .failure(.noMatch)
        }
        guard matches.count == 1, let match = matches.first else { return .failure(.ambiguous) }
        return .success(proposal(command.action, target: match.target, name: match.name))
    }

    /// A complete word (or words) at a word boundary: Alex matches Example Alex, never Alexandra.
    static func wordPrefix(_ phrase: String, in name: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?:\s|\z)"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func newestFirst(_ events: [Event]) -> [Event] {
        events.sorted {
            if $0.eventTime != $1.eventTime {
                return $0.eventTime > $1.eventTime
            }
            return scalarLess($0.id, $1.id)
        }
    }

    static func proposal(_ action: RuleProposal.Action, target: String, name: String) -> RuleProposal {
        let verb = switch action {
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .junk: "Junk"
        case .notJunk: "Not junk"
        case .vip: "VIP"
        case .unvip: "Not VIP"
        case .keywordUrgent: "Mark urgent"
        case .keywordHide: "Hide"
        case .removeKeyword: "Remove rule"
        }
        return RuleProposal(action: action, target: target, name: name, question: "\(verb) \(name)?")
    }
}

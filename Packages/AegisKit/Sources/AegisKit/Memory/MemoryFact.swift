import Foundation

/// Conservative admission for implicit memory. A verb somewhere in a chat line is not evidence of a fact.
/// Unrecognised statements stay in conversation; the owner can explicitly ask to remember any other note.
enum MemoryFact {
    static func isDurable(_ text: String) -> Bool {
        let line = text.replacingOccurrences(of: "’", with: "'")
        guard !line.isEmpty, !line.contains(where: { $0.isNewline || $0 == "?" || $0 == "？" }),
              !matches(uncertain, line), !matches(temporary, line), !matches(dependent, line),
              !Chat.isRequestToAct(line) else { return false }
        // A mixed turn is not one assertion. Dots inside an email or decimal are fine.
        guard !matches(#"[.!;]\s+\S"#, line) else { return false }
        if SenderAlias.parse(line) != nil {
            return true
        }
        return assertions.contains { matches($0, line) }
    }

    /// Select only facts actually stated in the input; model guesses and paraphrases cannot create new memories.
    /// The stored words come from the owner, not the model. Only case, punctuation and common contractions vary.
    static func supported(_ proposed: [String], by statements: [String], toOwner: Bool = false) -> [String] {
        let keys = Set(proposed.map(key))
        var seen = Set<String>()
        return statements.filter(isDurable).compactMap { original in
            let text = toOwner ? MemoryText.sentence(MemoryText.toOwner(original)) : original
            let normal = key(text)
            guard keys.contains(normal), seen.insert(normal).inserted else { return nil }
            return text
        }
    }

    private static func key(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "’", with: "'").lowercased()
        for (from, to) in [("i'm", "i am"), ("i've", "i have"), ("you're", "you are"), ("don't", "do not"), ("can't", "cannot")] {
            line = line.replacingOccurrences(of: #"\b"# + from + #"\b"#, with: to, options: .regularExpression)
        }
        // Keep numbers and identity punctuation: a different email or phone must not become a match.
        return line.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func matches(_ pattern: String, _ line: String) -> Bool {
        line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let uncertain = #"[?？]|^[\"“>]|\b(?:what|who|whose|when|where|why|how|which|whether|if|maybe|perhaps|suppose|imagine)\b|"#
        + #"\b(?:can|could|would|will|do|did|have) you\b|\b(?:tell me|show me|help me|(?:do not|don't|never) (?:remember|save|store|learn|record))\b"#
    private static let dependent = #"^(?:it|that|this|they|he|she|these|those|there)\b|\b(?:it|that|this|something|anything)\s*[.!]*$"#
    private static let temporary = #"\b(?:today|tonight|tomorrow|yesterday|now|earlier|later|currently|just|tired|hungry|thirsty|bored|sleepy|confused)\b|"#
        + #"\bthis (?:morning|afternoon|evening|week|weekend)\b"#

    private static let assertions = [
        // Stable preferences, constraints, work, home and ongoing projects; no generic “I have/am …” fallback.
        #"^i (?:like|love|prefer|hate|dislike|(?:don't|do not) like|(?:can't|cannot) eat|(?:don't|do not) eat)\s+\S.+$"#,
        #"^i (?:work|live|study) (?:at|in|for|as|on) \S.+$"#,
        #"^(?:i am|i'm) (?:called |named |allergic to |vegetarian\b|vegan\b|lactose intolerant\b|training for |studying |working (?:at|for|on) )\S*.*$"#,
        #"^(?:i am|i'm) an? (?:[a-z]+ ){0,3}(?:engineer|developer|designer|teacher|doctor|nurse|student|artist|writer|carer|parent|vegetarian|vegan)\b.*$"#,
        #"^i (?:have|have got|'ve got) (?:an? |\d+ |one |two |three )?(?:allergy|allergies|intolerance|sister|brother|child|children|son|daughter|dog|cat)\b.+$"#,
        #"^i was born \S.+$"#,
        #"^my (?:name|birthday|birth date|pronouns|address|phone(?: number)?|email(?: address)?|"#
            + #"time ?zone|job|employer|gym|dentist|doctor|diet|allergies|partner|wife|husband|sister|brother|mother|father|son|daughter|goal|project|"#
            + #"(?:sister|brother|mother|father|partner)'s name|favourite .+?|favorite .+?|preferred .+?) (?:is|are) \S.+$"#,
        #"^on (?:mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays) i (?:work|study|train|volunteer)\b.+$"#,
        #"^for my birthday i would like \S.+$"#,
        // Named people: relationships and stable employment/home facts, never arbitrary event assertions.
        #"^[\p{L}][\p{L}'-]*(?: [\p{L}][\p{L}'-]*){0,3} is my (?:brother|sister|mother|father|parent|son|daughter|child|partner|wife|husband|friend|colleague|doctor|dentist)\b.*$"#,
        #"^[\p{L}][\p{L}'-]*(?: [\p{L}][\p{L}'-]*){0,3} (?:works|lives|studies) (?:at|in|for|as) \S.+$"#,
    ]
}

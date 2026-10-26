import Foundation

/// What the owner asked of Aegis's memory (#222). Parsed only from the owner's own words in the panel or by
/// voice, never from collected content.
public enum MemoryCommand: Sendable, Equatable {
    /// "Remember that my locker code is 4312": the thing to remember.
    case remember(String)
    /// "Forget my locker code": what to forget; "everything", or "that" for the latest note.
    case forget(String)
    /// "What do you remember?"
    case list
    /// "When I say catch me up, tell me what's up": a phrase and what it stands for.
    case shortcut(trigger: String, action: String)
    /// "Do that again."
    case again
    /// "What did I ask you yesterday?": "today", "yesterday" or "earlier".
    case history(String)
    /// "Stop learning about me" (false) or "you can learn about me again" (true) (#282).
    case learning(Bool)
    /// "What have you learned about me?" (#282)
    case learned

    /// The longest line read as a command, in Unicode scalars.
    public static let maxScalars = CoreRequest.maxQuestionScalars

    public static func parse(_ text: String) -> MemoryCommand? {
        guard text.unicodeScalars.count <= maxScalars else { return nil }
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        let line = cleaned(text)
        guard !line.isEmpty else { return nil }
        let lower = line.lowercased()
        // A polite explicit request may end in '?'; a bare "forget everything?" is not consent.
        let requested = text.range(
            of: #"\b(?:can|could|would|will) you\s+(?:please\s+)?(?:remember that|forget|clear your memory|wipe your memory)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if againLines.contains(lower) {
            return .again
        }
        if lower.range(of: listPattern, options: .regularExpression) != nil {
            return .list
        }
        if lower.range(of: learnedPattern, options: .regularExpression) != nil {
            return .learned
        }
        if lower.range(of: learningOffPattern, options: .regularExpression) != nil {
            return .learning(false)
        }
        if lower.range(of: learningOnPattern, options: .regularExpression) != nil {
            return .learning(true)
        }
        if let period = capture(historyPattern, in: lower) {
            let when = period.hasPrefix("yesterday") ? "yesterday" : period.hasPrefix("today") || period.hasPrefix("this") ? "today" : "earlier"
            return .history(when)
        }
        guard !asked || requested else { return nil }
        if lower.range(
            of: #"^(?:forget everything|forget it all|forget all of it|clear your memory|wipe your memory)$"#,
            options: .regularExpression
        ) != nil {
            return .forget("everything")
        }
        if [
            "forget it",
            "forget that",
            "forget about it",
            "forget about that",
            "don't remember that",
            "dont remember that",
            "do not remember that",
            "don't remember it",
            "dont remember it",
            "do not remember it",
        ].contains(lower) {
            return .forget("that")
        }
        if let what = capture(
            #"^(?:forget (?:that |about )?|delete the memory (?:about |of )?|stop remembering |(?:don't|dont|do not) remember )(.+)$"#,
            in: line
        ) {
            return .forget(what)
        }
        // "If I say I'm sick, will they believe me?" is a question, not a shortcut.
        if let shortcut = shortcut(line) {
            return shortcut
        }
        // "Remember to…" and "remember me to…" are reminders; "remember when…?" is a question.
        guard let what = capture(
            #"^(?:remember|don't forget|dont forget|do not forget|note|make a note|keep in mind)(?: that)?[,:]?\s+(.+)$"#,
            in: line
        ),
            what.lowercased().range(of: #"^(?:to|me to|when|what|who|where|how|if|whether)\b"#, options: .regularExpression) == nil
        else { return nil }
        // "Note" alone needs "that" ("note that…"), so "note the time" isn't a memory.
        if lower.hasPrefix("note "), !lower.hasPrefix("note that ") {
            return nil
        }
        return .remember(what)
    }

    private static let againLines: Set<String> = [
        "again", "do that again", "do it again", "same again", "repeat that", "say that again", "one more time", "repeat",
    ]

    private static let historyPattern = #"^(?:what did i (?:ask|say to|tell) you|what have i asked(?: you)?|"#
        + #"what did we (?:talk|chat) about|what were we talking about)\s+(yesterday|today|this morning|this afternoon|"#
        + #"earlier|before|last time)$"#

    /// A clear lasting fact about the owner, suitable for offering to save. Questions, requests, conversational
    /// fragments and temporary states are never suggestions; explicit “remember…” remains available for other notes.
    public static func suggestion(_ text: String) -> String? {
        guard text.split(whereSeparator: \.isWhitespace).count <= 30 else { return nil }
        return statedFact(text)
    }

    /// Only a positively recognised durable assertion can be saved without an explicit memory command.
    /// Checking the entire utterance matters: speech often puts a question between a greeting and a correction.
    static func statedFact(_ text: String) -> String? {
        guard text.unicodeScalars.count <= maxScalars, parse(text) == nil,
              !text.contains(where: { $0.isNewline || $0 == "?" || $0 == "？" }) else { return nil }
        let line = cleaned(text)
        return MemoryFact.isDurable(line) ? line : nil
    }

    private static let listPattern = #"^(?:what do you remember(?: about me)?|what have i told you(?: to remember)?|"#
        + #"what do you know about me|show me your memory|what'?s in your memory|what is in your memory)$"#

    private static let learnedPattern = #"^(?:what have you (?:learned|learnt|picked up) about me|what did you (?:learn|pick up) "#
        + #"about me|what have you learned|what have you learnt)$"#
    private static let learningOffPattern = #"^(?:stop|pause|quit) learning(?: about me| from me| from our chats)?$|"#
        + #"^(?:don't|dont|do not) learn (?:about|from) (?:me|our chats)$"#
    private static let learningOnPattern = #"^(?:start|resume|keep) learning(?: about me| from me| from our chats)?(?: again)?$|"#
        + #"^you can (?:learn about me|learn from our chats|start learning)(?: again)?$"#

    /// "When I say X, Y": X at most six words, Y at most 200 scalars.
    private static func shortcut(_ line: String) -> MemoryCommand? {
        // A quoted phrase needs no comma after it.
        let patterns = [
            #"^(?:when|whenever|if) i say\s+["“]([^"”]+)["”],?\s*(?:then\s+)?(.+)$"#,
            #"^(?:when|whenever|if) i say\s+(.+?)\s*(?:,|\bthen\b|\byou should\b|\bi want you to\b|\bplease\b)\s*(.+)$"#,
        ]
        guard let found = patterns.lazy.compactMap({ captures($0, in: line) }).first else { return nil }
        let (phrase, meaning) = found
        let trigger = MemoryText.normalise(phrase.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”‘’' ")))
        var action = meaning.trimmingCharacters(in: .whitespaces)
        for lead in ["then ", "you should ", "i want you to ", "please "] where action.lowercased().hasPrefix(lead) {
            action = String(action.dropFirst(lead.count))
        }
        guard action.range(
            of: #"^(?:will|would|can|could|should|do|does|did|is|are|was|were|have|has|what|why|when|where|who|how|which)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else { return nil }
        let words = trigger.split(separator: " ").count
        guard (1 ... 6).contains(words), !action.isEmpty, action.unicodeScalars.count <= 200 else { return nil }
        return .shortcut(trigger: trigger, action: action)
    }

    /// Without "hey Aegis,", "please" or "can you" in front, or "please", "thanks" and punctuation at the end.
    private static func cleaned(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let edges = [
            #"^(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s+"#, #"^(?:please|can you|could you|would you|will you)\s+"#,
            #"^(?:please)\s+"#, #"^(?:actually[, ]+|no,\s*|correction:\s*)"#, #"[\s.!?]+$"#, #"[,\s]+(?:please|thanks|thank you)$"#,
            #"[\s.!?]+$"#,
        ]
        for pattern in edges {
            line = line.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return line
    }

    private static func captures(_ pattern: String, in line: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let first = Range(match.range(at: 1), in: line), let second = Range(match.range(at: 2), in: line)
        else { return nil }
        return (String(line[first]), String(line[second]))
    }

    private static func capture(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        let value = String(line[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

import Foundation

/// A small, pure English heuristic for questions that need the previous owner's question to retrieve records.
enum FollowUpQuestion {
    /// Recognizes whole-word references and continuation openings. Capitalized words other than references,
    /// "I" and common question openings are treated as possible new names, so they prevent carrying context.
    /// This deliberately avoids guessing identities or resolving names without a contact index.
    static func leansOnPrevious(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter }.map(String.init)
        let lower = words.map { $0.lowercased() }
        guard let first = lower.first else { return false }
        let refersBack = lower.contains { references.contains($0) }
        let continues = first == "and"
            || Array(lower.prefix(2)) == ["what", "about"]
            || Array(lower.prefix(2)) == ["how", "about"]
            || Array(lower.prefix(2)) == ["what", "else"]
        guard refersBack || continues else { return false }
        return !words.enumerated().contains { index, word in
            let normalized = lower[index]
            return word.first?.isUppercase == true
                && !references.contains(normalized) && normalized != "i"
                && !(index == 0 && openings.contains(normalized))
        }
    }

    /// Whether a question carries on from the last exchange (#54): it refers back, only asks for more ("tell me
    /// more", "why?"), or shares a word with it ("the compressor" after Aegis described a heat pump).
    static func continues(_ question: String, from last: Chat.Turn, now: Date, calendar: Calendar) -> Bool {
        let words = AskQuery.words(question)
        let keywords = Set(AskQuery(question, now: now, calendar: calendar).keywords)
        return leansOnPrevious(question) || !words.isEmpty && words.allSatisfy(generic.contains)
            || !keywords.subtracting(generic).isDisjoint(with: AskQuery.words(last.owner + " " + last.aegis))
    }

    /// Words that ask for more of the same rather than name a subject ("tell me more", "why?", "go on", "how so?").
    private static let generic: Set<String> = [
        "more", "else", "again", "explain", "elaborate", "simpler", "simply", "shorter", "longer", "detail", "details",
        "example", "examples", "another", "continue", "keep", "going", "really", "mean", "means", "meant", "why",
        "tell", "me", "go", "on", "so", "how", "can", "could", "you", "please", "a", "an", "bit", "little", "give", "some",
    ]

    /// What to search for a follow-up: the previous question's words, then this one's. When this question names
    /// its own time ("and today?"), the previous question's time words go, so the newer time wins.
    static func search(_ question: String, after previous: String, now: Date, calendar: Calendar) -> String {
        let ownTime = AskQuery(question, now: now, calendar: calendar).messages != AskQuery("", now: now, calendar: calendar).messages
        guard ownTime else { return previous + " " + question }
        return previous.replacingOccurrences(of: timeWords, with: " ", options: [.regularExpression, .caseInsensitive]) + " " + question
    }

    private static let timeWords = #"\b(?:(?:this|last|next)\s+(?:morning|week|monday|tuesday|wednesday|thursday|friday|"#
        + #"saturday|sunday)|last\s+\d+\s+days|today|tonight|tomorrow|yesterday|monday|tuesday|wednesday|thursday|friday|"#
        + #"saturday|sunday)\b"#

    private static let references: Set<String> = [
        "she", "he", "they", "them", "her", "him", "his", "their", "it", "that", "this", "those", "these", "there",
    ]
    private static let openings: Set<String> = [
        "and", "what", "how", "when", "where", "why", "who", "whose", "which",
        "did", "does", "do", "is", "are", "was", "were", "can", "could", "would", "will", "should", "has", "have",
    ]
}

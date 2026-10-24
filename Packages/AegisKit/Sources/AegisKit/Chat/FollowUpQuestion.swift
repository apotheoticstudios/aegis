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

    /// Whether a question carries on from the conversation (#54) rather than asking about the owner's own records:
    /// it refers back, asks for more ("tell me more", "explain that again"), names something said in the last few
    /// exchanges ("what is a refrigerant?"), or is a few words ("how tall?"). Never when it says "my", names a day,
    /// or asks who told, sent or said something.
    static func continues(_ question: String, after turns: [Chat.Turn], now: Date, calendar: Calendar) -> Bool {
        let words = AskQuery.words(question)
        let query = AskQuery(question, now: now, calendar: calendar)
        let timed = query.messages != AskQuery("", now: now, calendar: calendar).messages
        guard !words.isEmpty, !timed, !words.contains(where: ownerWords.contains) else { return false }
        let said = Set(turns.suffix(3).flatMap { AskQuery.words($0.owner + " " + $0.aegis) })
        return leansOnPrevious(question) || words.allSatisfy { generic.contains($0) || references.contains($0) }
            || !Set(query.keywords).subtracting(generic).isDisjoint(with: said) || words.count <= 4
    }

    /// Words that ask for more of the same rather than name a subject ("tell me more", "why?", "go on", "how so?").
    private static let generic: Set<String> = [
        "more", "else", "again", "explain", "elaborate", "simpler", "simply", "shorter", "longer", "detail", "details",
        "example", "examples", "another", "continue", "keep", "going", "really", "mean", "means", "meant", "why",
        "tell", "me", "go", "on", "so", "how", "can", "could", "you", "please", "a", "an", "bit", "little", "give", "some",
        "say", "repeat", "describe", "the",
    ]

    /// Words that make a question about the owner's own messages, mail or calendar.
    private static let ownerWords: Set<String> = [
        "my", "told", "said", "says", "sent", "wrote", "asked", "messaged", "emailed", "texted", "replied", "mentioned",
        "called", "rang", "inbox", "email", "emails", "mail", "message", "messages", "texts", "calendar", "meeting",
        "appointment", "reminder", "reminders",
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
        "explain", "tell", "give", "describe", "say", "repeat", "go", "keep", "show", "expand", "clarify", "define",
        "did", "does", "do", "is", "are", "was", "were", "can", "could", "would", "will", "should", "has", "have",
    ]
}

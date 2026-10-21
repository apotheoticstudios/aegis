import Foundation

enum CommitmentVerb {
    case send, call, pay, book, check, getBack, finish, other
}

/// A deliberately narrow vocabulary: missing a promise is preferable to inventing one.
enum CommitmentDetection {
    private static let actions = #"send|email|text|message|call|ring|pay|transfer|book|bring|pick up|drop off|check|"#
        + #"look into|look at|get back to|let you know|fix|finish|sort(?: out)?|confirm|review|share|forward|"#
        + #"organise|organize|order|grab|buy|follow up|do (?:it|that)|have (?:it|that) (?:done|ready|sent)"#

    static func verb(in sentence: String, due: Date?) -> CommitmentVerb? {
        guard !sentence.hasSuffix("?") else { return nil }
        let text = CommitmentText.unquoted(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        let exclusions = #"\b(?:won't|will not|can't|cannot|couldn't|don't|might|maybe|probably|try|hopefully|if i)\b"#
        guard CommitmentText.match(exclusions, in: text) == nil else { return nil }
        if CommitmentText.match(#"^let me (?:check|find out|ask)\b"#, in: text) != nil {
            return .check
        }
        if CommitmentText.match(#"^(?:leave it with me|on it)\b"#, in: text) != nil {
            return .finish
        }
        let lead = #"^(?:i'll|i will|ill|i'm going to|i am going to)\s+(?:(?:just|definitely|def|also|then)\s+)?"#
        if let match = CommitmentText.match(lead + "(" + actions + #")\b"#, in: text) {
            return category(match[1].lowercased())
        }
        guard due != nil, let match = CommitmentText.match(#"^i can\s+("# + actions + #")\b"#, in: text) else { return nil }
        return category(match[1].lowercased())
    }

    private static func category(_ action: String) -> CommitmentVerb {
        switch action {
        case "send", "email", "text", "message", "share", "forward", "have it sent", "have that sent": .send
        case "call", "ring": .call
        case "pay", "transfer": .pay
        case "book": .book
        case "check", "look into", "look at", "review": .check
        case "get back to", "let you know", "follow up": .getBack
        case "fix", "finish", "sort", "sort out", "have it done", "have that done": .finish
        default: .other
        }
    }
}

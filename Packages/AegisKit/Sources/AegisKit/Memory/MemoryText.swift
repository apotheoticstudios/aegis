import Foundation

/// Text helpers for memory (#222): comparing the owner's phrasing and turning "my" into "your".
enum MemoryText {
    /// Lowercase words and apostrophes only, single-spaced, without a leading "aegis" or "hey aegis".
    static func normalise(_ text: String) -> String {
        let scalars = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
            }
        var words = String(scalars).split(separator: " ").map(String.init)
        for lead in [["hey", "aegis"], ["ok", "aegis"], ["okay", "aegis"], ["aegis"]] where words.starts(with: lead) {
            words.removeFirst(lead.count)
            break
        }
        return words.joined(separator: " ")
    }

    /// Content words for matching: no stopwords, no apostrophes, a final "s" dropped from longer words.
    static func tokens(_ text: String) -> Set<String> {
        Set(normalise(text).split(separator: " ").compactMap { word -> String? in
            var token = word.replacingOccurrences(of: "'", with: "")
            guard !token.isEmpty, !stopwords.contains(token) else { return nil }
            if token.count > 3, token.hasSuffix("s") {
                token.removeLast()
            }
            return token
        })
    }

    /// Share of the query's content words found in the other text: 0 when the query has none.
    static func overlap(_ query: Set<String>, _ other: String) -> Double {
        guard !query.isEmpty else { return 0 }
        return Double(query.intersection(tokens(other)).count) / Double(query.count)
    }

    /// The owner's words as Aegis says them back: "my locker code" → "your locker code". `startsSentence` false
    /// when the words follow others ("I'll remember that you…").
    static func toOwner(_ text: String, startsSentence: Bool = true) -> String {
        var line = text.replacingOccurrences(of: "’", with: "'")
        for (pattern, swap) in [(#"\bI am\b"#, "you are"), (#"\bI was\b"#, "you were")] {
            line = line.replacingOccurrences(of: pattern, with: swap, options: [.regularExpression, .caseInsensitive])
        }
        var result = ""
        var word = ""
        func flush() {
            defer { word = "" }
            guard let swap = swaps[word.lowercased()] else {
                result += word
                return
            }
            // "I" is always a capital; "you" is only at the start of a sentence.
            let lower = word.lowercased()
            let before = result.trimmingCharacters(in: .whitespaces)
            let capital = before.isEmpty ? startsSentence
                : lower == "i" || lower.hasPrefix("i'")
                ? before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?")
                : word.first?.isUppercase == true
            result += capital ? swap.prefix(1).uppercased() + swap.dropFirst() : swap
        }
        for character in line {
            if character.isLetter || character == "'" {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// First letter capitalised, ending with a full stop unless it already ends a sentence.
    static func sentence(_ text: String) -> String {
        let line = ended(text)
        guard let first = line.first else { return line }
        return first.uppercased() + line.dropFirst()
    }

    /// Ending with a full stop unless it already ends a sentence.
    static func ended(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty || line.hasSuffix(".") || line.hasSuffix("!") || line.hasSuffix("?") ? line : line + "."
    }

    private static let swaps: [String: String] = [
        "my": "your", "mine": "yours", "i": "you", "i'm": "you're", "im": "you're", "me": "you", "myself": "yourself",
        "our": "your", "ours": "yours", "we": "you", "us": "you", "we're": "you're", "we've": "you've",
        "i've": "you've", "i'll": "you'll", "i'd": "you'd",
    ]

    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "in", "on", "at", "for", "and", "or", "but", "my",
        "our", "your", "me", "i", "you", "it", "this", "that", "what", "whats", "when", "where", "who", "whos", "how", "do",
        "does", "did", "can", "could", "would", "will", "please", "tell", "about", "with", "have", "has", "had", "aegis",
        "hey", "ok", "okay", "just", "im", "its", "again", "remember", "know",
    ]
}

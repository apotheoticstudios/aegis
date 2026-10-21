import Foundation

/// Recognizes direct address in on-device microphone transcripts. Never use collected content as wake input.
public enum WakePhrase {
    /// A wake, optionally carrying a question spoken in the same breath.
    public struct Match: Equatable, Sendable {
        /// Original question text with outer punctuation removed; nil for fewer than two words.
        public let question: String?

        /// Creates a wake result with an optional question.
        public init(question: String?) {
            self.question = question
        }
    }

    private static let fillers: Set<String> = ["um", "so"]
    private static let greetings: Set<String> = ["hey", "hi", "ok", "okay", "yo", "hello"]
    private static let names: Set<String> = ["aegis", "aegis's", "jarvas", "aegiss", "javis", "jervis"]

    /// Accepts only leading fillers, an optional greeting, then a name within the first four words: "Aegis",
    /// or the owner's own name for Aegis (`also`, one word, #241).
    /// Case and punctuation are ignored for matching; contractions remain single words.
    public static func match(_ transcript: String, also name: String? = nil) -> Match? {
        let custom = name?.lowercased().trimmingCharacters(in: .whitespaces)
        let accepted = custom.map { names.union([$0, $0 + "'s"]) } ?? names
        guard let words = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#) else { return nil }
        let range = NSRange(transcript.startIndex..., in: transcript)
        let prefix = Array(words.matches(in: transcript, range: range).prefix(4))
        var index = 0
        while index < prefix.count, fillers.contains(word(prefix[index], in: transcript)) {
            index += 1
        }
        if index < prefix.count, greetings.contains(word(prefix[index], in: transcript)) {
            index += 1
        }
        guard index < prefix.count, accepted.contains(word(prefix[index], in: transcript)),
              let nameRange = Range(prefix[index].range, in: transcript)
        else { return nil }
        let trim = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let question = String(transcript[nameRange.upperBound...]).trimmingCharacters(in: trim)
        let questionRange = NSRange(question.startIndex..., in: question)
        let hasQuestion = words.numberOfMatches(in: question, range: questionRange) >= 2
        return Match(question: hasQuestion ? question : nil)
    }

    private static func word(_ result: NSTextCheckingResult, in transcript: String) -> String {
        guard let range = Range(result.range, in: transcript) else { return "" }
        return transcript[range].lowercased().replacingOccurrences(of: "’", with: "'")
    }
}

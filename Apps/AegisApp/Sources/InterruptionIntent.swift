import Foundation

/// Conservative turn-taking from temporary, on-device partial speech. Never runs while idle.
/// This detects conversational cues, not a speaker's identity or certainty about their intention.
enum InterruptionIntent {
    static func accepts(_ text: String, playback: String, addressed: Bool = false) -> Bool {
        let heard = words(text)
        guard !heard.isEmpty else { return false }
        // Echo cancellation is the first barrier. Reject residual words from the current spoken reply too.
        let spoken = words(playback, limit: .max)
        if !spoken.isEmpty, spoken.joined(separator: " ").contains(heard.joined(separator: " ")) {
            return false
        }
        if heard.count >= 3 {
            // Compare nearby words, not the vocabulary of an entire long brief. Otherwise common
            // words scattered across unrelated passages would suppress a real new question.
            for start in stride(from: 0, to: spoken.count, by: max(1, heard.count / 2)) {
                let spokenWords = Set(spoken[start ..< min(spoken.count, start + heard.count * 2)])
                let shared = heard.filter { spokenWords.contains($0) }.count
                if Double(shared) / Double(heard.count) >= 0.75 {
                    return false
                }
            }
        }
        if addressed {
            return true
        }
        return directed(heard)
    }

    /// Recognition can hallucinate a short cue from noise or revise an incomplete question. Require
    /// two consistent observations over a short interval; elapsed time alone never confirms a cue.
    struct Confirmation {
        private var pending: [String] = []
        private var since: TimeInterval?
        private var last: TimeInterval?

        mutating func reset() {
            self = Self()
        }

        mutating func accepts(_ text: String, playback: String, addressed: Bool = false, at time: TimeInterval) -> Bool {
            guard time.isFinite, last.map({ time > $0 }) ?? true,
                  InterruptionIntent.accepts(text, playback: playback, addressed: addressed)
            else {
                reset()
                return false
            }
            if addressed {
                reset()
                return true
            }
            let heard = InterruptionIntent.words(text)
            if let since, let last, time - last <= 1.5, heard.starts(with: pending) {
                if time - since >= 0.4 {
                    reset()
                    return true
                }
            } else {
                since = time
            }
            pending = heard
            last = time
            return false
        }
    }

    private static func directed(_ heard: [String]) -> Bool {
        var turn = heard
        while let first = turn.first, ["yeah", "yes", "okay", "ok", "right", "hey", "but", "please", "sorry", "um", "uh"].contains(first) {
            turn.removeFirst()
        }
        if turn.last == "please" {
            turn.removeLast()
        }
        guard let first = turn.first else { return false }
        if first == "actually" {
            return directed(Array(turn.dropFirst()))
        }
        if first == "stop" {
            return turn.count == 1 || ["talking", "speaking", "reading"].contains(turn[1])
        }
        if first == "wait" {
            return turn.count == 1 || ["a second", "a moment", "a minute"].contains(turn.dropFirst().joined(separator: " "))
                || directed(Array(turn.dropFirst()))
        }
        for cue in ["hold on", "hang on", "excuse me", "end conversation"] {
            let prefix = words(cue)
            if turn == prefix {
                return true
            }
            if cue != "end conversation", turn.starts(with: prefix), directed(Array(turn.dropFirst(prefix.count))) {
                return true
            }
        }
        let start = turn.prefix(3).joined(separator: " ")
        let cues = [
            "that is wrong", "that is not", "i meant", "i asked", "i said", "tell me", "show me", "go back",
            "can you", "could you", "would you", "will you", "do you", "did you", "are you",
        ]
        if first == "no" {
            return directed(Array(turn.dropFirst()))
        }
        guard !["a", "an", "the", "to", "about", "for", "with", "and", "but", "of"].contains(turn.last ?? "") else { return false }
        if ["explain", "repeat", "pause", "translate", "summarize", "summarise", "remember", "read"].contains(first) {
            return turn.count >= 2
        }
        guard turn.count >= 3 else { return false }
        if let cue = cues.first(where: { start == $0 || start.hasPrefix($0 + " ") }) {
            return cue == "that is wrong" || turn.count > words(cue).count
        }
        if ["is", "are", "was", "were", "did", "does", "do", "has", "have", "can", "should"].contains(first),
           ["that", "this", "it", "you", "i"].contains(turn[1])
        {
            return true
        }
        guard ["what", "where", "when", "who", "which", "why", "how"].contains(first) else { return false }
        return [
            "is", "are", "was", "were", "do", "does", "did", "can", "could", "would", "will", "should", "has", "have",
            "about", "time", "day", "much", "many", "long", "soon", "come", "happened", "sent", "asked", "said", "wrote", "called",
        ].contains(turn[1])
    }

    private static func words(_ text: String, limit: Int = 64) -> [String] {
        var text = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for (short, full) in [
            ("what's", "what is"),
            ("where's", "where is"),
            ("when's", "when is"),
            ("who's", "who is"),
            ("how's", "how is"),
            ("that's", "that is"),
        ] {
            text = text.replacingOccurrences(of: short, with: full)
        }
        return Array(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(limit).map(String.init))
    }
}

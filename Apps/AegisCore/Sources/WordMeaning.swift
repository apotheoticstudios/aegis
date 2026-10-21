import AegisKit
import NaturalLanguage

/// Memory recall by meaning (#305) with macOS's own on-device English word model: nothing downloaded, nothing
/// leaves the Mac. A note is related when one of the question's words is close to one of the note's ("sibling" and
/// "sister", "fitness centre" and "gym").
/// shortcut: word-level only, it misses brand names ("car" and "Mazda"); a small sentence-embedding model would
/// catch those, when recall needs it.
final class WordMeaning: MeaningScorer, @unchecked Sendable {
    /// Calibrated on synthetic notes: related pairs scored 0.49 to 0.59, unrelated ones at most 0.45.
    static let threshold = 0.48
    private let lock = NSLock()
    private var model: NLEmbedding?
    private var loaded = false

    func relatedness(_ question: String, _ note: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            model = NLEmbedding.wordEmbedding(for: .english)
            loaded = true
        }
        guard let model else { return nil }
        let asked = Self.words(question), noted = Self.words(note)
        let best = asked.compactMap { word in
            noted.map { 1 - model.distance(between: word, and: $0) / 2 }.max()
        }
        .max() ?? 0
        return best >= Self.threshold ? best : nil
    }

    private static let ignored: Set<String> = [
        "what", "did", "say", "about", "the", "when", "is", "my", "who", "how", "do", "get", "into", "tell", "me", "to",
        "in", "for", "like", "called", "and", "of", "it", "was", "are", "you", "your", "have", "has", "with", "that", "this",
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !ignored.contains($0) }
    }
}

import Foundation

/// The pinned keyword model uses SentencePiece unigram pieces. Encode a short, owner-chosen English name
/// with maximum-score segmentation; this is text configuration, never background speech recognition.
struct KeywordTokens {
    let scores: [String: Float]

    func encode(_ phrase: String) -> String? {
        let text = "▁" + phrase.uppercased().split(separator: " ").joined(separator: "▁")
        let letters = Array(text)
        guard letters.count <= 64 else { return nil }
        var best = [Float](repeating: -.infinity, count: letters.count + 1)
        var previous = [Int](repeating: -1, count: letters.count + 1)
        best[0] = 0
        for end in 1 ... letters.count {
            for start in 0 ..< end {
                let piece = String(letters[start ..< end])
                guard let score = scores[piece], best[start] + score > best[end] else { continue }
                best[end] = best[start] + score
                previous[end] = start
            }
        }
        guard previous[letters.count] >= 0 else { return nil }
        var pieces: [String] = []
        var end = letters.count
        while end > 0 {
            let start = previous[end]
            guard start >= 0 else { return nil }
            pieces.append(String(letters[start ..< end]))
            end = start
        }
        return pieces.reversed().joined(separator: " ")
    }

    static func keywords(directory: URL, name: String?) -> String? {
        guard let fixed = try? String(contentsOf: directory.appendingPathComponent("keywords.txt"), encoding: .utf8) else { return nil }
        guard let name, !name.isEmpty, name.count <= 40, name.lowercased() != "aegis",
              name.allSatisfy({ $0.isASCII && $0.isLetter }),
              let data = try? Data(contentsOf: directory.appendingPathComponent("token-scores.json")),
              let scores = try? JSONDecoder().decode([String: Float].self, from: data),
              let encoded = KeywordTokens(scores: scores).encode("HEY " + name)
        else { return fixed }
        return fixed.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + encoded + " @CUSTOM_NAME\n"
    }
}

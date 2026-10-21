// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/memory/extractor.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis;
// reads only the owner's own words (never Aegis's reply, which may quote collected messages); asks for facts in
// the owner's first person so they fit MemoryBook; the line fallback accepts only bulleted or numbered lines.
import Foundation

/// Automatic memory (#282): the prompt that asks the local model for lasting facts in what the owner said, and the
/// parser that turns its answer into a clean, deduplicated, capped list. Best effort: bad output gives no facts.
public enum FactExtractor {
    /// At most this many facts from one batch.
    public static let maxFacts = 10
    /// Longer facts are cut to this many characters.
    public static let maxFactCharacters = 200
    /// At most this many of the owner's lines go to the model at once, newest kept.
    public static let maxLines = 8
    /// Tokens the model may write.
    public static let maxTokens = 512

    /// OpenJarvis's extraction prompt, adapted to the owner's own words and first person.
    public static let systemPrompt = """
    You extract durable, long-term facts about the owner from things the owner said to their assistant. \
    A good fact is stable over time and useful in future conversations: preferences, identity, goals, ongoing \
    projects, constraints, or relationships. Ignore one-off task details, small talk, questions, requests, and \
    anything about the assistant itself. Write each fact in the owner's own words and first person, for example \
    "I prefer morning meetings" or "My sister is called Sam".

    Respond with ONLY a JSON array of short fact strings (each under 200 characters). If there is nothing worth \
    remembering, respond with [].
    """

    /// True for a line that could hold a fact: a few words, not just a greeting or thanks.
    public static func worthReading(_ line: String) -> Bool {
        let words = line.split { $0.isWhitespace }
        guard words.count >= 4, line.unicodeScalars.count <= CoreRequest.maxQuestionScalars else { return false }
        return !Chat.isSmallTalk(line) || words.count >= 8
    }

    /// The model job for a batch of the owner's lines.
    public static func job(owner lines: [String], model: String, now: Date) throws -> ModelJob {
        let said = lines.suffix(maxLines).map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
        let user = "THE OWNER SAID:\n" + said.joined(separator: "\n")
        return try ModelJob(
            id: "learn-" + UUID().uuidString.lowercased(), model: model, system: systemPrompt, user: user,
            maxTokens: min(maxTokens, ModelJob.maxOutputTokens), deadline: now.addingTimeInterval(90),
            inputRevision: SHA256.hex(Array(user.utf8))
        )
    }

    /// Parses model output into a clean, deduplicated, capped list of facts. Never throws.
    public static func parse(_ content: String) -> [String] {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var facts: [String] = []
        var seen = Set<String>()
        for item in coerceToList(content) {
            let fact = clean(item)
            guard !fact.isEmpty, seen.insert(fact.lowercased()).inserted else { continue }
            facts.append(fact)
            if facts.count >= maxFacts {
                break
            }
        }
        return facts
    }

    /// A JSON array anywhere in the output (models often wrap it in prose or code fences), else bulleted lines.
    static func coerceToList(_ content: String) -> [String] {
        if let open = content.firstIndex(of: "["), let close = content.lastIndex(of: "]"), open < close,
           let array = try? JSONSerialization.jsonObject(with: Data(content[open ... close].utf8)) as? [Any]
        {
            return array.map { ($0 as? String) ?? "\($0)" }
        }
        // Unlike OpenJarvis, prose lines are not facts: "There is nothing to remember." must not become one.
        return content.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let marker = text.range(of: #"^(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
            return String(text[marker.upperBound...])
        }
    }

    private static func clean(_ item: String) -> String {
        var fact = item.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty, !["[]", "none", "n/a", "null"].contains(fact.lowercased()) else { return "" }
        if fact.count > maxFactCharacters {
            fact = String(fact.prefix(maxFactCharacters)).trimmingCharacters(in: .whitespaces)
        }
        return fact
    }
}

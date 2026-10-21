// The observation rules are adapted from Hindsight (vectorize-io/hindsight on GitHub),
// hindsight_api/engine/consolidation/prompts.py, Copyright Vectorize, MIT. Changes: condensed for a small local
// model; observations replace each other instead of being updated one by one.
import Foundation

/// Reflecting on what Aegis knows about the owner (#315), after Hindsight's consolidation: the local model turns the
/// owner's notes into a few observations. Only the owner's own words and facts learned from them go in.
public enum Reflection {
    /// New learned facts since the last reflection before Aegis reflects again.
    public static let due = 10
    public static let maxObservations = 5
    /// The newest notes the model reads.
    public static let maxNotes = 60

    public static let systemPrompt = """
    You consolidate what an assistant knows about its owner into observations. Rules: each observation covers exactly \
    one facet (a relationship, a routine, a preference, a goal or an ongoing project); say only what the notes support \
    and never calculate, guess or adjust numbers; keep different people and topics separate; when notes conflict, the \
    newer note wins; skip momentary chatter. Write each observation as one short sentence to the owner ("You…").

    Reply with ONLY a JSON array of at most 5 strings. If the notes support nothing beyond what they already say, \
    reply with [].
    """

    /// The model job for these notes (newest last), or nil when there are none.
    public static func job(notes: [MemoryNote], model: String, now: Date) throws -> ModelJob? {
        let lines = notes.suffix(maxNotes).map { "- " + $0.text.replacingOccurrences(of: "\n", with: " ") }
        guard !lines.isEmpty else { return nil }
        let user = "THE OWNER'S NOTES, OLDEST FIRST:\n" + lines.joined(separator: "\n")
        return try ModelJob(
            id: "reflect-" + UUID().uuidString.lowercased(), model: model, system: systemPrompt, user: user,
            maxTokens: 300, deadline: now.addingTimeInterval(90), inputRevision: SHA256.hex(Array(user.utf8))
        )
    }
}

public extension MemoryBook {
    /// True when enough new facts were learned since the last reflection, and learning isn't paused.
    var reflectionDue: Bool {
        learningPaused != true
            && notes.count { $0.origin == .learned && $0.createdAt > (reflectedAt ?? .distantPast) } >= Reflection.due
    }

    /// What reflection reads: the owner's own notes and learned facts, oldest first; never shortcuts, quarantined or
    /// earlier observations.
    var reflectionNotes: [MemoryNote] {
        notes.filter { $0.kind != .shortcut && ($0.origin == nil || $0.origin == .owner || $0.origin == .learned) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Replaces the previous observations with these (at most five) and records the time.
    mutating func reflect(_ observations: [String], now: Date, id: () -> String = MemoryBook.newID) {
        notes.removeAll { $0.origin == .reflected }
        for text in observations.prefix(Reflection.maxObservations) {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty, words.unicodeScalars.count <= Self.maxNoteScalars else { continue }
            add(MemoryNote(id: id(), kind: .fact, text: words, createdAt: now, origin: .reflected))
        }
        reflectedAt = now
    }
}

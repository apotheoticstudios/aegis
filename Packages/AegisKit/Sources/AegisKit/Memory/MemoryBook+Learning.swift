import Foundation

/// Automatic memory (#282), after OpenJarvis's trust tiers (memory/store.py, Apache-2.0): facts Aegis picks up from
/// the owner's own words are kept as learned notes; ones the injection scanner flags are quarantined (kept so the
/// owner can see and forget them, never used in a reply). What the owner asked Aegis to remember always wins.
public extension MemoryBook {
    /// At most this many usable learned notes; the least recently used goes first.
    static let maxLearned = 200
    /// At most this many quarantined notes.
    static let maxQuarantined = 20

    /// Learned notes, usable and quarantined.
    var learned: [MemoryNote] {
        notes.filter(\.isLearned)
    }

    /// Keeps learned facts; returns how many notes were added or changed. The same words as any note refresh it; a
    /// new value for something learned ("my gym is…") replaces the old one; the owner's own notes are never changed.
    @discardableResult
    mutating func learn(
        _ facts: [String], quarantined: [String] = [], now: Date, id: () -> String = MemoryBook.newID
    ) -> Int {
        let tagged = facts.map { ($0, MemoryNote.Origin.learned) } + quarantined.map { ($0, MemoryNote.Origin.quarantined) }
        var changed = 0
        for (text, origin) in tagged {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty, words.unicodeScalars.count <= Self.maxNoteScalars,
                  origin == .quarantined || MemoryCommand.statedFact(words) != nil else { continue }
            let key = MemoryText.normalise(words)
            if let index = notes.firstIndex(where: { $0.kind != .shortcut && MemoryText.normalise($0.text) == key }) {
                notes[index].lastUsedAt = now
                continue
            }
            if let subject = Self.subject(of: words),
               let index = notes.firstIndex(where: { $0.kind == .fact && Self.subject(of: $0.text) == subject })
            {
                guard notes[index].isLearned else { continue }
                notes[index].text = words
                notes[index].origin = origin
                notes[index].lastUsedAt = now
                changed += 1
                continue
            }
            guard makeRoom(for: origin) else { continue }
            add(MemoryNote(id: id(), kind: Self.kind(of: words), text: words, createdAt: now, origin: origin))
            changed += 1
        }
        return changed
    }

    /// Frees a place for a new learned note by dropping the least recently used one of the same origin.
    private mutating func makeRoom(for origin: MemoryNote.Origin) -> Bool {
        let limit = origin == .quarantined ? Self.maxQuarantined : Self.maxLearned
        let same = notes.indices.filter { notes[$0].origin == origin }
        if same.count >= limit || notes.count >= Self.maxNotes {
            guard let stale = same.min(by: {
                (notes[$0].lastUsedAt ?? notes[$0].createdAt) < (notes[$1].lastUsedAt ?? notes[$1].createdAt)
            }) else { return false }
            notes.remove(at: stale)
        }
        return true
    }
}

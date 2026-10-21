import Foundation

/// Everything Aegis remembers (#222): the owner's notes and recent exchanges, kept on this Mac only and never sent
/// to a cloud model. Only the owner's own words become notes; collected content never does.
public struct MemoryBook: Codable, Sendable, Equatable {
    public var notes: [MemoryNote]
    public var exchanges: [PastExchange]
    /// The owner said "stop learning about me" (#282); nil or false means Aegis learns from chats.
    public var learningPaused: Bool?
    /// When Aegis last reflected on its notes (#315); nil in older files.
    public var reflectedAt: Date?

    public static let empty = MemoryBook()
    public static let maxNotes = 500
    public static let maxNoteScalars = CoreRequest.maxQuestionScalars
    public static let maxExchanges = 300
    /// How long exchanges are kept, in days.
    public static let exchangeDays = 90.0

    public init(notes: [MemoryNote] = [], exchanges: [PastExchange] = []) {
        self.notes = notes
        self.exchanges = exchanges
    }

    /// A new note ID: "mem_" and 12 hex characters.
    public static func newID() -> String {
        "mem_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }

    /// Keeps the owner's words. The same words again refresh the note; a new value for the same thing ("my locker
    /// code is…") replaces the old one, and a learned note the owner restates becomes theirs. Nil when empty or longer
    /// than `maxNoteScalars`.
    public mutating func remember(_ text: String, now: Date, id: () -> String = MemoryBook.newID) -> MemoryNote? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.unicodeScalars.count <= Self.maxNoteScalars else { return nil }
        if let alias = SenderAlias.parse(words), let index = notes.firstIndex(where: {
            $0.kind == .fact && SenderAlias.parse($0.text)?.key == alias.key
        }) {
            notes[index].text = words
            notes[index].lastUsedAt = now
            notes[index].origin = nil
            return notes[index]
        }
        let key = MemoryText.normalise(words)
        if let index = notes.firstIndex(where: { $0.kind != .shortcut && MemoryText.normalise($0.text) == key }) {
            notes[index].lastUsedAt = now
            notes[index].origin = nil
            return notes[index]
        }
        if let subject = Self.subject(of: words),
           let index = notes.firstIndex(where: { $0.kind == .fact && Self.subject(of: $0.text) == subject })
        {
            notes[index].text = words
            notes[index].lastUsedAt = now
            notes[index].origin = nil
            return notes[index]
        }
        guard notes.count < Self.maxNotes else { return nil }
        let note = MemoryNote(id: id(), kind: Self.kind(of: words), text: words, createdAt: now)
        add(note)
        return note
    }

    /// Keeps a phrase and what it stands for; the same phrase again replaces its meaning.
    @discardableResult
    public mutating func addShortcut(
        trigger: String, action: String, now: Date, id: () -> String = MemoryBook.newID
    ) -> MemoryNote {
        let phrase = MemoryText.normalise(trigger)
        if let index = notes.firstIndex(where: { $0.kind == .shortcut && $0.trigger == phrase }) {
            notes[index].text = action
            notes[index].lastUsedAt = now
            return notes[index]
        }
        let note = MemoryNote(id: id(), kind: .shortcut, text: action, trigger: phrase, createdAt: now)
        add(note)
        return note
    }

    /// Removes what the owner named: "everything", "that" (the newest note), or the best match. Returns what went.
    public mutating func forget(_ query: String) -> [MemoryNote] {
        if let key = SenderAlias.handleKey(query), let index = notes.firstIndex(where: {
            $0.kind == .fact && SenderAlias.parse($0.text)?.key == key
        }) {
            return [notes.remove(at: index)]
        }
        switch query.lowercased() {
        case "everything":
            defer { notes = [] }
            return notes
        case "that":
            guard let newest = notes.indices.max(by: { notes[$0].createdAt < notes[$1].createdAt }) else { return [] }
            return [notes.remove(at: newest)]
        default:
            let scored = notes.indices.map { ($0, relevance(notes[$0], to: query)) }.filter { $0.1 >= 0.5 }
            guard let best = scored.max(by: { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : notes[lhs.0].createdAt < notes[rhs.0].createdAt
            }) else { return [] }
            return [notes.remove(at: best.0)]
        }
    }

    /// Removes one note by ID; false when there's none.
    public mutating func forget(id: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        notes.remove(at: index)
        return true
    }

    /// The shortcut whose phrase is exactly what the owner said, counted as used.
    public mutating func shortcut(for text: String, now: Date) -> MemoryNote? {
        let phrase = MemoryText.normalise(text)
        guard !phrase.isEmpty, let index = notes.firstIndex(where: { $0.kind == .shortcut && $0.trigger == phrase }) else {
            return nil
        }
        notes[index].uses += 1
        notes[index].lastUsedAt = now
        return notes[index]
    }

    /// Keeps an exchange: the newest `maxExchanges`, none older than `exchangeDays`.
    public mutating func record(_ exchange: PastExchange) {
        let oldest = exchange.at.addingTimeInterval(-Self.exchangeDays * 86400)
        exchanges = Array((exchanges.filter { $0.at >= oldest } + [exchange]).suffix(Self.maxExchanges))
    }

    /// How much of the owner's question a note covers, from 0 to 1.
    public func relevance(_ note: MemoryNote, to text: String) -> Double {
        MemoryText.overlap(MemoryText.tokens(text), note.text + " " + (note.trigger ?? ""))
    }

    /// Facts and shortcuts for the question: those covering at least half of its words, fused with those related
    /// by meaning when a scorer is given (#305), best first.
    public func relevant(to text: String, limit: Int = 5, meaning: (any MeaningScorer)? = nil) -> [MemoryNote] {
        let query = MemoryText.tokens(text)
        var scored: [(note: MemoryNote, score: Double)] = []
        for note in notes where note.kind != .preference && note.origin != .quarantined {
            let score = MemoryText.overlap(query, note.text + " " + (note.trigger ?? ""))
            if score >= 0.5 {
                scored.append((note, score))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.note.createdAt > rhs.note.createdAt
        }
        guard let meaning else { return scored.prefix(limit).map(\.note) }
        let related = notes.filter { $0.kind != .preference && $0.origin != .quarantined }
            .compactMap { note in meaning.relatedness(text, note.text).map { (note, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.createdAt > $1.0.createdAt }
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return RankFusion.fuse([scored.map(\.note.id), related.map(\.0.id)]).prefix(limit).compactMap { byID[$0] }
    }

    /// The newest eight preferences, oldest first: they shape every reply.
    public var preferences: [MemoryNote] {
        Array(notes.filter { $0.kind == .preference && $0.origin != .quarantined }.sorted { $0.createdAt < $1.createdAt }.suffix(8))
    }

    /// An instant answer from a remembered fact, without the model: "what's my locker code?" → "Your locker code is
    /// 4312." Only when the question asks about exactly what a note says ("my locker code is…"); never a guess.
    public mutating func directAnswer(to question: String, now: Date) -> String? {
        let line = question.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"(?:\s+again)?[\s?.!]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let answer = senderAnswer(line) {
            return answer
        }
        let patterns = [
            #"^(?:what|when|where|who|which|how much|how many)(?:'s|s| is| are| was| were)\s+(.+)$"#,
            #"^do you (?:remember|know) (?:what |when |where |who |which )?(.+?)(?:\s+(?:is|are|was|were))?$"#,
        ]
        guard let asked = patterns.lazy.compactMap({ Self.capture($0, in: line) }).first else { return nil }
        let subject = Self.key(asked)
        guard let index = notes
            .firstIndex(where: {
                $0.kind == .fact && $0.origin != .quarantined && (Self.subject(of: $0.text) ?? Self.namedSubject(of: $0.text)) == subject
            })
        else {
            return nil
        }
        notes[index].uses += 1
        notes[index].lastUsedAt = now
        return MemoryText.sentence(MemoryText.toOwner(notes[index].text))
    }

    /// Earlier exchanges (before `before`) that share at least half of the question's words, newest first.
    public func earlier(about text: String, before: Date, limit: Int = 3, meaning: (any MeaningScorer)? = nil) -> [PastExchange] {
        let query = MemoryText.tokens(text)
        let past = exchanges.indices.filter { exchanges[$0].at < before }.reversed()
        let byWords = past.filter { MemoryText.overlap(query, exchanges[$0].owner + " " + exchanges[$0].aegis) >= 0.5 }
        guard let meaning else { return byWords.prefix(limit).map { exchanges[$0] } }
        // By meaning too (#307): the owner's own words, fused with Hindsight's rank fusion like notes (#305).
        let byMeaning = past.compactMap { index in meaning.relatedness(text, exchanges[index].owner).map { (index, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        return RankFusion.fuse([byWords.map(String.init), byMeaning.map(String.init)]).prefix(limit)
            .compactMap { Int($0).map { exchanges[$0] } }
    }

    /// What Aegis's conversation sees: the owner's preferences, facts that bear on the question, and earlier
    /// exchanges about it (not the last few minutes, which the conversation already holds).
    public func notesForChat(_ text: String, now: Date, calendar: Calendar, meaning: (any MeaningScorer)? = nil) -> [String] {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_AU")
        day.dateFormat = "EEE d MMM"
        var lines = preferences.map {
            ($0.isLearned ? "You learned from the owner (preference): " : "The owner asked you to remember (preference): ") + $0.text
        }
        lines += upcoming(now: now, calendar: calendar).map { "Coming up, from what the owner told you: " + $0.line }
        lines += relevant(to: text, meaning: meaning).filter { $0.kind == .fact }.map {
            ($0.origin == .reflected ? "You noticed about the owner (may be wrong; " : $0.isLearned ? "You learned from the owner ("
                : "The owner told you (") + day.string(from: $0.createdAt) + "): " + $0.text
        }
        lines += earlier(about: text, before: now.addingTimeInterval(-Chat.memory), meaning: meaning).map {
            "Earlier (\(day.string(from: $0.at))): the owner said \"\(Self.cut($0.owner))\"; you said \"\(Self.cut($0.aegis))\""
        }
        return lines
    }

    /// A remembered date in the coming days ("Mum's birthday is 3 March"), with how many days away it is.
    public struct Upcoming: Sendable, Equatable {
        public let note: MemoryNote
        public let date: Date
        public let days: Int

        /// "Mum's birthday is 3 March (in 2 days)", as Aegis says it to the owner.
        public var line: String {
            let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
            return MemoryText.toOwner(note.text).trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")) + " (\(when))"
        }
    }

    /// Facts with a day and month that fall within `days` from today, soonest first: birthdays, anniversaries,
    /// due dates. Each comes round every year.
    public func upcoming(now: Date, calendar: Calendar, within days: Int = 7) -> [Upcoming] {
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        return notes.filter { $0.kind == .fact && $0.origin != .quarantined }.compactMap { note -> Upcoming? in
            guard let (month, day) = Self.monthDay(in: note.text) else { return nil }
            for candidate in [year, year + 1] {
                guard let date = calendar.date(from: DateComponents(year: candidate, month: month, day: day)),
                      calendar.component(.day, from: date) == day, date >= today
                else { continue }
                let away = calendar.dateComponents([.day], from: today, to: date).day ?? 0
                return away <= days ? Upcoming(note: note, date: date, days: away) : nil
            }
            return nil
        }
        .sorted { $0.date < $1.date }
    }

    /// The first "3 March", "3rd of March" or "March 3" in a note.
    static func monthDay(in text: String) -> (Int, Int)? {
        let months = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let lower = text.lowercased()
        let patterns = [
            (#"\b(\d{1,2})(?:st|nd|rd|th)?(?: of)? "# + months + #"\b"#, true),
            (#"\b"# + months + #" (\d{1,2})(?:st|nd|rd|th)?\b"#, false),
        ]
        for (pattern, dayFirst) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let first = Range(match.range(at: 1), in: lower), let second = Range(match.range(at: 2), in: lower)
            else { continue }
            let dayText = String(lower[dayFirst ? first : second])
            let monthText = String(lower[dayFirst ? second : first])
            guard let day = Int(dayText), (1 ... 31).contains(day),
                  let month = names.firstIndex(where: { monthText.hasPrefix($0) })
            else { continue }
            return (month + 1, day)
        }
        return nil
    }

    // MARK: - Helpers

    mutating func add(_ note: MemoryNote) {
        notes.append(note)
        while notes.count > Self.maxNotes,
              let stale = (notes.contains { $0.kind != .shortcut }
                  ? notes.indices.filter { notes[$0].kind != .shortcut } : Array(notes.indices))
              .min(by: { (notes[$0].lastUsedAt ?? notes[$0].createdAt) < (notes[$1].lastUsedAt ?? notes[$1].createdAt) })
        {
            notes.remove(at: stale)
        }
    }

    static func kind(of text: String) -> MemoryNote.Kind {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return preferenceLeads.contains { lower.hasPrefix($0 + " ") } ? .preference : .fact
    }

    private static let preferenceLeads = [
        "i like", "i love", "i prefer", "i don't like", "i dont like", "i do not like", "i hate", "i want you to",
        "i'd like you to", "i would like you to", "always", "never", "call me", "don't", "do not", "please",
    ]

    /// What a "subject is value" fact is about ("my locker code", "mum's birthday"), for replacing and recalling.
    static func subject(of text: String) -> String? {
        let pattern = #"^((?:my|our|the)\s+[^,.;]{1,40}?|[\p{L}']+(?:'s|s')(?:\s+[^,.;]{1,40}?)?)\s+(?:is|are|was|were)\s+\S.*$"#
        guard let found = capture(pattern, in: text.replacingOccurrences(of: "’", with: "'")) else { return nil }
        return key(found)
    }

    /// A person's statement can be recalled by name without replacing other facts about that person.
    private static func namedSubject(of text: String) -> String? {
        capture(#"^([\p{L}][\p{L}'-]*(?: [\p{L}'-]+){0,4})\s+(?:is|are|was|were)\s+.+$"#, in: text).map(key)
    }

    /// Lowercase, without apostrophes, single-spaced.
    static func key(_ text: String) -> String {
        MemoryText.normalise(text).replacingOccurrences(of: "'", with: "")
    }

    private static func cut(_ text: String) -> String {
        text.unicodeScalars.count > 200 ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(199))) + "…" : text
    }

    private static func capture(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[range])
    }
}

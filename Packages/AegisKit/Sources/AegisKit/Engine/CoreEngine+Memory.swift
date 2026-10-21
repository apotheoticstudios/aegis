import Foundation

/// Aegis's memory (#222): "remember…", "forget…", "what do you remember?", shortcuts, "do that again" and instant
/// answers from remembered facts. Only the owner's words in `ask` reach this path; none of it needs the model.
extension CoreEngine {
    /// The owner's question after "do that again" and shortcuts are expanded (once), or a reply when there's
    /// nothing to repeat.
    func expanded(_ question: String) -> (question: String, reply: CoreResponse?) {
        if MemoryCommand.parse(question) == .again {
            guard let last = conversation.last?.owner ?? memory.exchanges.last?.owner else {
                return (question, memoryAnswer("There's nothing to do again yet.", question: question))
            }
            return (last, nil)
        }
        if let shortcut = memory.shortcut(for: question, now: clock()) {
            saveMemory()
            return (shortcut.text, nil)
        }
        return (question, nil)
    }

    /// A reply from memory, or nil when the question isn't for memory.
    func memoryResponse(_ question: String) -> CoreResponse? {
        let now = clock()
        let previous = memory
        switch MemoryCommand.parse(question) ?? MemoryCommand.statedFact(question).map(MemoryCommand.remember) {
        case var .remember(text):
            // "Remember that" on its own: what the owner just told Aegis, never Aegis's reply (which may hold
            // collected content).
            if ["that", "this", "it", "that one"].contains(text.lowercased()) {
                guard let said = conversation.last?.owner, MemoryCommand.parse(said) == nil, QuickAnswer.answer(
                    said,
                    now: now,
                    calendar: calendar
                ) == nil,
                    !said.trimmingCharacters(in: .whitespaces).hasSuffix("?")
                else {
                    return memoryAnswer("Tell me what to remember, like “remember that my locker code is 4312”.", question: question)
                }
                text = said.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
            }
            guard let note = memory.remember(text, now: now) else {
                let message = memory.notes.count >= MemoryBook.maxNotes
                    ? "My memory is full. Please forget an old note before adding another; I kept your existing notes."
                    : "That's a bit long for me to remember. Could you say it shorter?"
                return memoryAnswer(message, question: question)
            }
            guard saveMemory() else { return memoryWriteFailed(previous, question: question) }
            let reply = note.kind == .preference
                ? "Noted. I'll keep that in mind."
                : "Got it. I'll remember that " + MemoryText.ended(MemoryText.toOwner(note.text, startsSentence: false))
            return memoryAnswer(reply, question: question)
        case let .forget(query):
            let gone = memory.forget(query)
            guard saveMemory() else { return memoryWriteFailed(previous, question: question) }
            let reply = switch (query, gone.first) {
            case (_, nil): "I don't have anything like that to forget."
            case ("everything", _): "Done. I've forgotten everything you asked me to remember."
            case let (_, note?): "Done. I've forgotten " + Self.quoted(note) + "."
            }
            return memoryAnswer(reply, question: question)
        case .list, .learned:
            return listOrLearning(MemoryCommand.parse(question) == .learned ? .learned : .list, previous: previous, question: question)
        case let .learning(on):
            return listOrLearning(.learning(on), previous: previous, question: question)
        case let .shortcut(trigger, action):
            guard memory.notes.count < MemoryBook.maxNotes || memory.notes.contains(where: { $0.trigger == MemoryText.normalise(trigger) })
            else { return memoryAnswer("My memory is full. Please forget an old note first.", question: question) }
            memory.addShortcut(trigger: trigger, action: action, now: now)
            guard saveMemory() else { return memoryWriteFailed(previous, question: question) }
            return memoryAnswer("Got it. When you say “\(trigger)”, I'll take it as: \(action)", question: question)
        case let .history(period):
            return memoryAnswer(history(period, now: now), question: question)
        case .again, nil:
            guard let answer = memory.directAnswer(to: question, now: now) else { return nil }
            saveMemory()
            return memoryAnswer(answer, question: question)
        }
    }

    /// "What do you remember?", "what have you learned about me?" and pausing or resuming learning (#282).
    private func listOrLearning(_ command: MemoryCommand, previous: MemoryBook, question: String) -> CoreResponse {
        switch command {
        case .list:
            let newest = memory.notes.filter { !$0.isLearned }.sorted { $0.createdAt > $1.createdAt }
            let learned = memory.learned.filter { $0.origin == .learned }.count
            let picked = learned == 0 ? "" : ", and I've picked up \(learned == 1 ? "one thing" : "\(learned) things") from our chats"
            guard !newest.isEmpty else {
                return memoryAnswer(
                    learned == 0 ? "You haven't asked me to remember anything yet."
                        : "You haven't asked me to remember anything yet" + picked + ". Ask what I've learned to hear it.",
                    question: question
                )
            }
            let count = newest.count == 1 ? "one thing" : "\(newest.count) things"
            let latest = newest.prefix(3).map(Self.quoted).joined(separator: "; ")
            return memoryAnswer("You've asked me to remember \(count)\(picked). The latest: \(latest).", question: question)
        case .learned:
            let newest = memory.learned.filter { $0.origin == .learned }.sorted { $0.createdAt > $1.createdAt }
            guard !newest.isEmpty else {
                let paused = memory.learningPaused == true ? " Learning is paused; say “you can learn about me again” to restart it." : ""
                return memoryAnswer("I haven't picked anything up from our chats yet." + paused, question: question)
            }
            let latest = newest.prefix(3).map(Self.quoted).joined(separator: "; ")
            let count = newest.count == 1 ? "one thing" : "\(newest.count) things"
            return memoryAnswer(
                "I've picked up \(count) from our chats. The latest: \(latest). Say “forget…” to drop one.",
                question: question
            )
        case let .learning(on):
            memory.learningPaused = on ? nil : true
            if !on {
                learnQueue = []
                learnTicket = nil
            }
            guard saveMemory() else { return memoryWriteFailed(previous, question: question) }
            return memoryAnswer(
                on ? "Okay. I'll learn from what you tell me in our chats again."
                    : "Okay. I'll stop learning from our chats. What I've already learned stays until you ask me to forget it.",
                question: question
            )
        default:
            return memoryAnswer("You haven't asked me to remember anything yet.", question: question)
        }
    }

    /// What the owner asked today, yesterday or before this conversation: the latest three, oldest first.
    private func history(_ period: String, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        let asked: [PastExchange] = switch period {
        case "today": memory.exchanges.filter { $0.at >= today }
        case "yesterday": memory.exchanges.filter { $0.at < today && $0.at >= today.addingTimeInterval(-86400) }
        default: memory.exchanges.filter { $0.at < now.addingTimeInterval(-Chat.memory) }
        }
        let questions = asked.suffix(3).map { "“" + $0.owner.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")) + "”" }
        let when = period == "earlier" ? "Earlier" : period == "today" ? "Today" : "Yesterday"
        guard !questions.isEmpty else {
            return period == "earlier" ? "We haven't talked before this." : "You didn't ask me anything \(period)."
        }
        return when + " you asked " + (asked.count > 3 ? "\(asked.count) things; the latest: " : "") + questions.joined(separator: "; ") + "."
    }

    /// The panel's memory list, newest first (#222), and the personality (#241).
    func memoryRequest(_ request: CoreRequest) -> CoreResponse? {
        switch request {
        case .personality:
            return .personality(personality)
        case let .setPersonality(chosen):
            guard let cleaned = chosen.cleaned else { return .refused(code: "bad_personality") }
            if let personalityFile {
                guard (try? personalityFile.save(cleaned)) != nil else { return .refused(code: "personality_unwritable") }
            }
            personality = cleaned
            return .personality(cleaned)
        case .memories:
            return .memories(memory.notes.sorted { $0.createdAt > $1.createdAt })
        case let .forgetMemory(id):
            guard id.unicodeScalars.count <= 64 else { return .refused(code: "bad_memory") }
            let previous = memory
            guard memory.forget(id: id) else { return .refused(code: "unknown_memory") }
            guard saveMemory() else { memory = previous; return .refused(code: "memory_unwritable") }
            return .memories(memory.notes.sorted { $0.createdAt > $1.createdAt })
        default:
            return nil
        }
    }

    /// The same corrected index is used for briefs, retrieval, preparation and cloud privacy filtering.
    func contactIndex() async -> ContactIndex? {
        let base = await contacts?.index()
        let aliases = memory.senderAliases
        guard base != nil || !aliases.isEmpty else { return nil }
        var index = base ?? ContactIndex([])
        index.preservesUnmatchedContacts = base == nil
        index.apply(aliases)
        return index
    }

    /// An existing brief may contain an old sender name. Requote affected citations with the corrected identity.
    func correctedMemoryItems(_ items: [Brief.Item], events: [String: Event]) -> [Brief.Item] {
        let keys = Set(memory.senderAliases.map(\.key))
        guard !keys.isEmpty else { return items }
        let contacts = BriefLayout.contactIDs(events)
        let corrected = items.flatMap { item -> [Brief.Item] in
            let cited = item.eventIDs.compactMap { events[$0] }
            guard cited.count == item.eventIDs.count, cited.contains(where: {
                $0.senderHandle.flatMap(SenderAlias.handleKey).map(keys.contains) == true
            }) else { return [item] }
            let incoming = cited.filter { !SenderDisplay.isOutgoing($0) && !BriefLayout.plantedOrder($0) }
            let quotes = incoming.compactMap { event -> Brief.Item? in
                guard var quote = BriefLayout.quote(event, priority: item.priority) else { return nil }
                quote.person = BriefLayout.person(of: [event], contacts: contacts)
                return quote
            }
            return quotes.isEmpty ? [item] : quotes
        }
        return Array(corrected.prefix(BriefLayout.maxTidiedItems))
    }

    private func memoryWriteFailed(_ previous: MemoryBook, question: String) -> CoreResponse {
        memory = previous
        return memoryAnswer("I couldn't save that to memory. Please try again.", question: question)
    }

    @discardableResult
    func saveMemory() -> Bool {
        guard let memoryFile else { return true }
        return (try? memoryFile.save(memory)) != nil
    }

    private func memoryAnswer(_ text: String, question: String) -> CoreResponse {
        remember(question, text)
        return .answer(Answer(text: text, eventIDs: [], scheduleIDs: [], model: "memory", generatedAt: clock()))
    }

    private static func quoted(_ note: MemoryNote) -> String {
        if note.kind == .shortcut, let trigger = note.trigger {
            return "the shortcut “\(trigger)”"
        }
        let text = note.text.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        return "“" + scalarPrefix(text, 300) + (text.unicodeScalars.count > 300 ? "…" : "") + "”"
    }
}

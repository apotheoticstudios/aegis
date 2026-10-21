import Foundation

/// Brief input, model draft and named source snapshots.
extension CoreEngine {
    /// Runs the model and checks its draft. `.completed` only when the whole result may be published.
    func draft(_ job: ScheduledBriefJob) async -> ModelJobResult.Status {
        let end = job.inputTime ?? clock()
        let start = job.opening.addingTimeInterval(-options.lookback)
        do {
            // Senders are named from Contacts by handle only (#85), never from message text. Notification
            // twins merge into their Messages records, so items cite the conversation (#153); three days
            // before the window serve only as context for questions.
            let contextStart = start.addingTimeInterval(-options.contextLookback)
            let merged = try await EventMerger.merge(named(allEvents(from: contextStart, to: end)))
            let events = rules.visible(merged)
            let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let input = try BriefInputPolicy(
                windowStart: start, windowEnd: end, contextStart: contextStart,
                ownerRules: rules, contacts: BriefLayout.contactIDs(byID)
            ).build(events)
            let request = try ModelJob(
                id: job.id, model: options.modelName, system: Briefing.systemPrompt(), user: input.text,
                maxTokens: options.maxTokens, deadline: job.deadline,
                inputRevision: SHA256.hex(Array(input.text.utf8))
            )
            guard request.validate().isEmpty else {
                return .failed
            }
            guard cancelRequested != job.id else {
                return .cancelled
            }
            let result = try await model.run(request)
            guard result.status == .completed else {
                return result.status
            }
            guard let text = result.text, let answer = Briefing.extractJSON(text) else {
                return .failed
            }
            // The brief checks (#94): every citation in this exact input, no planted order ranked urgent, no
            // attempted action, within budget; malformed items are dropped and counted.
            var resultCheck = BriefChecks.check(
                answer, input: input, events: byID, windowStart: start, windowEnd: end,
                model: options.modelName, generatedAt: clock()
            )
            if case .failure(.tooManyUrgent) = resultCheck {
                // Correct labels only, preserving all text, citations and fields for the same full checks.
                resultCheck = BriefChecks.check(
                    Self.capUrgentLabels(answer), input: input, events: byID, windowStart: start, windowEnd: end,
                    model: options.modelName, generatedAt: clock()
                )
            }
            guard case let .success(checkedBrief) = resultCheck else {
                return .failed
            }
            let brief = checkedBrief.brief
            let sources = sourceCoverage(at: clock())
            checked = (job.id, StoredBrief(
                brief: brief, inputRevision: request.inputRevision, coverage: sources, storedAt: clock()
            ))
            return .completed
        } catch {
            return .failed
        }
    }

    /// A model may rank too many items urgent; retain its ordering and cap labels without changing evidence.
    static func capUrgentLabels(_ draft: [String: Any]) -> [String: Any] {
        guard let items = draft["items"] as? [[String: Any]] else { return draft }
        var corrected = draft
        var urgent = 0
        corrected["items"] = items.map { original in
            var item = original
            if item["priority"] as? String == "urgent" {
                urgent += 1
                if urgent > BriefChecks.maxUrgent {
                    item["priority"] = "reply"
                }
            }
            return item
        }
        return corrected
    }

    /// Events with senders resolved from the owner's contacts, when Contacts can be read.
    func named(_ events: [Event]) async -> [Event] {
        await learnOwner(from: events)
        guard var index = await contactIndex() else {
            return ownersMarked(events)
        }
        for handle in ownerHandles {
            index.addOwner(handle: handle)
        }
        return resolveSenders(events, index: index)
    }

    /// Without Contacts: only the owner's own mail is marked theirs; everything else is left as collected.
    private func ownersMarked(_ events: [Event]) -> [Event] {
        guard !ownerHandles.isEmpty else { return events }
        var owner = ContactIndex([])
        for handle in ownerHandles {
            owner.addOwner(handle: handle)
        }
        return events.map { event in
            guard event.direction != .outgoing, let handle = event.senderHandle, owner.isOwner(handle: handle) else { return event }
            var mine = event
            mine.direction = .outgoing
            mine.senderContact = nil
            return mine
        }
    }

    /// The addresses the owner's sent mail comes from (#218): learned once from the last 30 days, then from each
    /// batch, so mail between the owner's own accounts is theirs, never someone waiting on them.
    private func learnOwner(from events: [Event]) async {
        if !ownerLearned {
            ownerLearned = true
            let now = clock()
            if let recent = try? await allEvents(from: now.addingTimeInterval(-30 * 86400), to: now) {
                ownerHandles.formUnion(Self.sentFrom(recent))
            }
        }
        ownerHandles.formUnion(Self.sentFrom(events))
    }

    static func sentFrom(_ events: [Event]) -> Set<String> {
        Set(events.filter { $0.source == .email && SenderDisplay.isOutgoing($0) }.compactMap { $0.senderHandle?.lowercased() })
    }

    /// Every event in the window, oldest first, read page by page on the store's (time, ID) keyset.
    func allEvents(from start: Date, to end: Date) async throws -> [Event] {
        var events: [Event] = []
        var cursor: EventCursor?
        while true {
            let page = try await store.events(from: start, to: end, after: cursor, limit: options.pageSize)
            events += page
            guard page.count == options.pageSize, let last = page.last else {
                return events
            }
            cursor = EventCursor(after: last)
        }
    }
}

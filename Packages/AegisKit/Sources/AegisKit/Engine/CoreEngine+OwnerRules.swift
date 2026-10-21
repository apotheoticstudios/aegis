import Foundation

/// The owner's plain-language input (#179). Collected text is used only to resolve target identities.
extension CoreEngine {
    func interpret(_ text: String) async -> CoreResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= RuleCommands.maxScalars,
              let command = RuleCommands.parse(trimmed)
        else { return .refused(code: "not_a_command") }
        if RuleCommands.isKeyword(command.action) {
            return resolved(command, events: [])
        }
        do {
            let now = clock()
            let events = try await EventMerger.merge(named(allEvents(from: now.addingTimeInterval(-30 * 86400), to: now)))
            return resolved(command, events: events)
        } catch {
            return .refused(code: "store_unavailable")
        }
    }
}

/// The owner's visibility rules (#175), junk in the last day (#167) and people waiting (#165).
extension CoreEngine {
    /// Apply in memory only after the file accepted the complete change; no suspension between the two.
    private func saveRules(_ updated: OwnerRules) -> Bool {
        do {
            try rulesFile?.save(updated)
            rules = updated
            return true
        } catch {
            return false
        }
    }

    private func resolved(_ command: RuleCommands.ParsedCommand, events: [Event]) -> CoreResponse {
        switch RuleCommands.resolve(command, events: events, rules: rules) {
        case let .success(proposal): .proposal(proposal)
        case let .failure(refusal): .refused(code: refusal.rawValue)
        }
    }

    /// Saves person and keyword priority changes before changing the live snapshot.
    func priorityResponse(_ request: CoreRequest) -> CoreResponse? {
        var updated = rules
        let valid: Bool
        let code: String
        switch request {
        case let .vip(personID, name):
            valid = updated.prioritise(personID, name: name)
            code = "bad_person"
        case let .unvip(personID):
            valid = updated.unprioritise(personID)
            code = "bad_person"
        case let .addKeyword(phrase, effect):
            valid = updated.addKeyword(phrase, effect: effect)
            code = "bad_keyword"
        case let .removeKeyword(phrase):
            valid = updated.removeKeyword(phrase)
            code = "bad_keyword"
        default:
            return nil
        }
        guard valid else { return .refused(code: code) }
        guard saveRules(updated) else { return .refused(code: "rules_unwritable") }
        return .rules(rules)
    }

    /// Junk and "Not junk" are mutually exclusive; either change returns the updated Filtered list.
    func changeSender(_ handle: String, junk: Bool) async -> CoreResponse {
        var updated = rules
        guard junk ? updated.markJunk(handle) : updated.notJunk(handle) else { return .refused(code: "bad_handle") }
        guard saveRules(updated) else { return .refused(code: "rules_unwritable") }
        return await filtered()
    }

    /// A nil name undoes a mute; either operation is saved before the rules response.
    func changeMute(_ personID: String, name: String?) -> CoreResponse {
        var updated = rules
        let valid = name.map { updated.mute(personID, name: $0) } ?? updated.unmute(personID)
        guard valid else { return .refused(code: "bad_person") }
        guard saveRules(updated) else { return .refused(code: "rules_unwritable") }
        return .rules(rules)
    }

    /// Rules take effect on a stored brief immediately. Missing citations keep the item, conservatively.
    func latestBrief() async throws -> StoredBrief? {
        guard var stored = try await store.latestBrief() else { return nil }
        guard !memory.senderAliases.isEmpty || !rules.junk.isEmpty || !rules.muted.isEmpty || !rules.vip.isEmpty || !rules.keywords.isEmpty
        else { return stored }
        let ids = Array(Set(stored.brief.items.flatMap(\.eventIDs))).sorted()
        let events = try await named(store.events(ids: ids))
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contacts = BriefLayout.contactIDs(byID)
        stored.brief.items = correctedMemoryItems(stored.brief.items, events: byID)
        stored.brief.items.removeAll { item in
            !item.eventIDs.isEmpty && item.eventIDs.allSatisfy { id in
                guard let event = byID[id] else { return false }
                return rules.hide(event, contacts: contacts) != nil
            }
        }
        stored.brief.items = BriefLayout.ownerPrioritised(stored.brief.items, events: byID, rules: rules)
        return stored
    }

    /// The last week's messages, named and with notification twins merged (#165).
    func people() async -> CoreResponse {
        do {
            let now = clock()
            let events = try await EventMerger.merge(named(allEvents(from: now.addingTimeInterval(-7 * 86400), to: now)))
            return .people(PeopleWaiting.compute(events: rules.visible(events), now: now, maxPeople: 12))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }

    /// Compute only on a panel request; a dismissal changes metadata, never active owner rules.
    func ruleSuggestions(dismissing dismissal: (personID: String, kind: RuleSuggestion.Kind)? = nil) async -> CoreResponse {
        if let dismissal, !OwnerRules.validPersonID(dismissal.personID) || dismissal.personID.unicodeScalars.count > 320 {
            return .refused(code: "bad_person")
        }
        do {
            let now = clock()
            guard let start = calendar.date(byAdding: .day, value: -14, to: now),
                  let expiry = calendar.date(byAdding: .day, value: 30, to: now) else { return .refused(code: "store_unavailable") }
            let events = try await EventMerger.merge(named(allEvents(from: start, to: now.addingTimeInterval(1))))
            if let dismissal {
                // Re-read live rules after the snapshot's suspension, preserving concurrent owner edits.
                var updated = rules
                updated.suggestionDismissals.removeAll {
                    $0.expiresAt <= now || ($0.personID == dismissal.personID && $0.kind == dismissal.kind)
                }
                updated.suggestionDismissals.append(.init(personID: dismissal.personID, kind: dismissal.kind, expiresAt: expiry))
                guard saveRules(updated) else { return .refused(code: "rules_unwritable") }
            }
            return .ruleSuggestions(RuleSuggestions.compute(events: events, rules: rules, now: now, calendar: calendar))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }

    /// Keeps private store access here; the additive endpoint lives in its own extension file.
    func commitmentSnapshot() async throws -> CommitmentSnapshot {
        let now = clock()
        let events = try await EventMerger.merge(named(allEvents(from: now.addingTimeInterval(-7 * 86400), to: now)))
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return CommitmentSnapshot(
            events: rules.visible(events), contacts: BriefLayout.contactIDs(byID),
            now: now, calendar: calendar, muted: Set(rules.muted.keys)
        )
    }

    /// Additive, read-only reply suggestions (#176), using the same visible snapshot as `people()`.
    func draftReply(personID: String) async -> CoreResponse {
        guard personID.unicodeScalars.count <= 320,
              ["contact:", "group:", "handle:"].contains(where: { prefix in
                  personID.hasPrefix(prefix)
                      && !personID.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return .refused(code: "bad_person") }
        if generating {
            return .refused(code: "busy")
        }
        do {
            let now = clock()
            let events = try await EventMerger.merge(named(allEvents(from: now.addingTimeInterval(-7 * 86400), to: now)))
            guard let input = ReplyDrafts.prepare(personID: personID, now: now, calendar: calendar, events: rules.visible(events)) else {
                return .refused(code: "nothing_open")
            }
            // A brief may have started while the snapshot was loaded, just as with other actor requests.
            if generating {
                return .refused(code: "busy")
            }
            let job = ModelJob(
                id: "draft-" + UUID().uuidString.lowercased(), model: options.modelName, system: ReplyDrafts.systemPrompt(),
                user: input.text, maxTokens: min(Self.answerTokens, ModelJob.maxOutputTokens),
                deadline: clock().addingTimeInterval(120), inputRevision: SHA256.hex(Array(input.text.utf8))
            )
            guard job.validate().isEmpty else { return .refused(code: "too_long") }
            let result = try await model.run(job)
            guard result.status == .completed else { return .refused(code: result.status.rawValue) }
            guard let text = result.text, let draft = Briefing.extractJSON(text) else {
                return .refused(code: DraftRejection.invalidDraft.rawValue)
            }
            switch ReplyDrafts.check(draft, input: input, person: input.person, model: options.modelName, generatedAt: clock()) {
            case let .success(reply): return .draft(reply)
            case let .failure(rejection): return .refused(code: rejection.rawValue)
            }
        } catch {
            return .refused(code: "failed")
        }
    }

    func filtered() async -> CoreResponse {
        do {
            let now = clock()
            let events = try await EventMerger.merge(named(allEvents(from: now.addingTimeInterval(-86400), to: now)))
            return .filtered(Filtered.compute(events: events, rules: rules, maxSenders: 20))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }
}

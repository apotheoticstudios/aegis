import Foundation

/// Meeting preparation (#184): read-only answers from attendee contact, checked like Ask.
extension CoreEngine {
    func prep(_ occurrenceID: String) async -> CoreResponse {
        if generating {
            return .refused(code: "busy")
        }
        let now = clock()
        do {
            let occurrences = try await store.occurrences(
                from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(14 * 86400)
            )
            guard let occurrence = occurrences.first(where: { $0.id == occurrenceID }) else {
                return .refused(code: "unknown_occurrence")
            }
            guard occurrence.attendees?.contains(where: { !$0.isOwner }) == true else {
                return .answer(MeetingPrep.emptyAnswer(for: occurrence, generatedAt: now))
            }
            let events = try await named(allEvents(from: now.addingTimeInterval(-14 * 86400), to: now))
            let input = try await MeetingPrep.prepare(
                occurrence: occurrence, events: events, contacts: contactIndex(), rules: rules, now: now, calendar: calendar
            )
            if input.isEmpty {
                return .answer(MeetingPrep.emptyAnswer(for: occurrence, generatedAt: now))
            }
            return try await prepAnswer(input)
        } catch {
            return .refused(code: "unavailable")
        }
    }

    private func prepAnswer(_ input: AskInput) async throws -> CoreResponse {
        let job = ModelJob(
            id: "prep-" + UUID().uuidString.lowercased(), model: options.modelName, system: MeetingPrep.systemPrompt(),
            user: input.text, maxTokens: min(Self.answerTokens, ModelJob.maxOutputTokens),
            deadline: clock().addingTimeInterval(120), inputRevision: SHA256.hex(Array(input.text.utf8))
        )
        guard job.validate().isEmpty else { return .refused(code: "too_long") }
        let result = try await model.run(job)
        guard result.status == .completed else { return .refused(code: result.status.rawValue) }
        guard let text = result.text, let draft = Briefing.extractJSON(text) else {
            return .refused(code: AskRejection.invalidDraft.rawValue)
        }
        switch Ask.check(draft, input: input, model: options.modelName, generatedAt: clock()) {
        case let .success(answer): return .answer(answer)
        case let .failure(reason): return .refused(code: reason.rawValue)
        }
    }
}

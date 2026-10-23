import Foundation

/// Request dispatch and the panel's read-only source and schedule requests.
extension CoreEngine {
    /// Answers an owner panel request; collected content can never invoke this path.
    public func handle(_ request: CoreRequest) async -> CoreResponse {
        if let response = await readResponse(request) ?? priorityResponse(request) ?? memoryRequest(request) {
            return response
        }
        if let response = await completionResponse(request) {
            return response
        }
        switch request {
        case .filtered:
            return await filtered()
        case let .trustSender(handle):
            return await changeSender(handle, junk: false)
        case let .markJunk(handle):
            return await changeSender(handle, junk: true)
        case .rules:
            return .rules(rules)
        case .ruleSuggestions:
            return await ruleSuggestions()
        case let .morningRoutine(skills):
            return await morningRoutine(skills: skills)
        case let .decideRoutine(ids, approved, always):
            return await decideRoutine(ids, approved: approved, always: always)
        case let .routineDone(id, succeeded):
            return routineDone(id, succeeded: succeeded)
        case let .dismissSuggestion(personID, kind):
            return await ruleSuggestions(dismissing: (personID, kind))
        case let .handedOff(question, reply, provider):
            return handedOff(question, reply: reply, provider: provider)
        case let .mute(personID, name):
            return changeMute(personID, name: name)
        case let .unmute(personID):
            return changeMute(personID, name: nil)
        case .refreshBrief:
            return await refreshBrief()
        case let .setBriefTime(minutes):
            return await setBriefTime(minutes)
        case .tuneUp:
            return await tuneUp()
        default:
            return .refused(code: "unsupported_request")
        }
    }

    func readResponse(_ request: CoreRequest) async -> CoreResponse? {
        switch request {
        case .partialReply:
            return await partialReply()
        case .latestBrief:
            do {
                return try await .brief(latestBrief())
            } catch {
                return .refused(code: "store_unavailable")
            }
        case .status:
            return .status(status())
        case .prepareModel:
            return prepareModel()
        case let .sources(ids):
            return await sourceEvents(ids)
        case let .schedule(start, end):
            return await scheduleItems(from: start, to: end)
        case .ask, .prep, .converse, .worldPlan, .commandPlan:
            return await answerResponse(request)
        case let .interpret(text):
            return await interpret(text)
        case .people:
            return await people()
        case let .draftReply(personID):
            return await draftReply(personID: personID)
        case let .activity(hours):
            return await activity(hours: hours)
        default:
            return nil
        }
    }

    private func answerResponse(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case let .ask(question): await ask(question)
        case let .converse(question, cloud): await ask(question, cloud: cloud)
        case let .prep(occurrenceID): await prep(occurrenceID)
        case let .worldPlan(question): await worldPlan(question)
        case let .commandPlan(question, shortcuts): await commandPlan(question, shortcuts: shortcuts)
        default: .refused(code: "unsupported_request")
        }
    }

    private func sourceEvents(_ ids: [String]) async -> CoreResponse {
        guard ids.count <= CoreRequest.maxSourceIDs else { return .refused(code: "too_many_ids") }
        do {
            return try await .events(named(store.events(ids: ids)))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }

    private func scheduleItems(from start: Date, to end: Date) async -> CoreResponse {
        guard start <= end, end.timeIntervalSince(start) <= Double(CoreRequest.maxScheduleDays) * 86400 else {
            return .refused(code: "bad_window")
        }
        do {
            return try await .schedule(
                occurrences: store.occurrences(from: start, to: end), reminders: store.reminders(from: start, to: end)
            )
        } catch {
            return .refused(code: "store_unavailable")
        }
    }
}

/// The serial lane: schedule changes run one at a time; a waiter receives the lane already held.
extension CoreEngine {
    func acquire() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    /// Hands the lane to the next waiter, which keeps it held.
    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Ask Aegis anything (#163): read-only answers from the owner's own data, one model job at a time.
extension CoreEngine {
    /// Tokens for an answer: a few sentences plus citations.
    static let answerTokens = 400

    func ask(_ question: String, cloud: CloudHandOff.Availability = .none) async -> CoreResponse {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, asked.unicodeScalars.count <= CoreRequest.maxQuestionScalars else {
            return .refused(code: "bad_question")
        }
        let turn = UUID()
        currentQuestion = turn
        await pauseLearning()
        if let job = questionJobID {
            await model.cancel(jobID: job)
        }
        guard currentQuestion == turn else { return .refused(code: "cancelled") }
        if clock().timeIntervalSince(conversationAt) > Chat.memory {
            conversation = []
        }
        // "Do that again" and the owner's shortcuts first; memory needs no model, so it answers even while busy.
        let (expandedQuestion, nothing) = expanded(asked)
        if let response = nothing ?? memoryResponse(expandedQuestion) {
            return response
        }
        // The time, the date, sums and conversions: answered at once, exactly (#227).
        if let quick = QuickAnswer.answer(expandedQuestion, now: clock(), calendar: calendar) {
            remember(expandedQuestion, quick)
            return .answer(Answer(text: quick, eventIDs: [], scheduleIDs: [], model: "aegis", generatedAt: clock()))
        }
        // "Ask Claude…" and follow-ups to a hand-off (#223): they don't need the local model either.
        // Expanded words come from memory, which ADR-0017 never permits sending to a provider.
        let fromMemory = expandedQuestion != asked
        let (trimmed, note, handedOff) = fromMemory
            ? (expandedQuestion, nil as String?, nil as CoreResponse?)
            : await handOff(expandedQuestion, cloud: cloud)
        if let handedOff {
            return handedOff
        }
        guard currentQuestion == turn else { return .refused(code: "cancelled") }
        let response = await answer(trimmed, cloud: fromMemory ? .none : cloud, turn: turn)
        return note.map { Self.noted(response, $0) } ?? response
    }

    private func answer(_ trimmed: String, cloud: CloudHandOff.Availability, turn: UUID) async -> CoreResponse {
        await interruptBriefForQuestion()
        await acquire()
        defer { release() }
        guard currentQuestion == turn else { return .refused(code: "cancelled") }
        do {
            let input = try await Ask.prepare(
                question: trimmed, now: clock(), calendar: calendar, store: store, contacts: contactIndex()
            )
            guard currentQuestion == turn else { return .refused(code: "cancelled") }
            if let text = input.directAnswer {
                return .answer(Answer(text: text, eventIDs: [], scheduleIDs: [], model: "aegis", generatedAt: clock()))
            }
            if input.isEmpty, FollowUpQuestion.leansOnPrevious(trimmed), let last = conversation.last, last.via == nil {
                let followInput = try await Ask.prepare(
                    question: last.owner + " " + trimmed, now: clock(), calendar: calendar, store: store, contacts: contactIndex()
                )
                guard currentQuestion == turn else { return .refused(code: "cancelled") }
                // The earlier question supplies retrieval terms only; its records stay local as conversation NOTES.
                if !followInput.isEmpty {
                    return await chat(trimmed, found: Chat.contextLines(followInput.text), turn: turn)
                }
            }
            // Small talk, general questions and anything the owner's data doesn't cover: a conversation (#194),
            // or, with automatic hand-off on, Claude or ChatGPT for a complex general question (#223).
            if (Chat.isSmallTalk(trimmed) && !input.prefersGrounded) || Chat.isRequestToAct(trimmed) || input.isEmpty {
                if input.isEmpty, let request = await CloudHandOff.automatic(trimmed, available: cloud, names: contactNames()) {
                    return .handOff(request)
                }
                return await chat(trimmed, found: [], turn: turn)
            }
            let job = try ModelJob(
                id: "ask-" + UUID().uuidString.lowercased(), model: options.modelName, system: Ask.systemPrompt(),
                user: input.text, maxTokens: min(Self.answerTokens, ModelJob.maxOutputTokens),
                deadline: clock().addingTimeInterval(120), inputRevision: SHA256.hex(Array(input.text.utf8))
            )
            guard job.validate().isEmpty else {
                return .refused(code: "too_long")
            }
            let result = try await runQuestionJob(job, turn: turn)
            guard result.status == .completed else {
                return .refused(code: result.status.rawValue)
            }
            guard let text = result.text, let draft = Briefing.extractJSON(text) else {
                return .refused(code: AskRejection.invalidDraft.rawValue)
            }
            switch Ask.check(draft, input: input, model: options.modelName, generatedAt: clock()) {
            case let .success(answer):
                remember(trimmed, answer.text)
                return .answer(answer)
            case let .failure(reason):
                // A rejected grounded answer must never escape through unchecked conversation.
                return .refused(code: reason.rawValue)
            }
        } catch {
            return .refused(code: "unavailable")
        }
    }
}

/// Jobs belong to one owner question. Superseded jobs cannot publish text or enter conversation memory.
extension CoreEngine {
    func runQuestionJob(_ job: ModelJob, turn: UUID) async throws -> ModelJobResult {
        guard currentQuestion == turn else { return ModelJobResult(jobID: job.id, status: .cancelled) }
        questionJobID = job.id
        defer {
            if questionJobID == job.id {
                questionJobID = nil
            }
        }
        let result = try await model.run(job)
        guard currentQuestion == turn else { return ModelJobResult(jobID: job.id, status: .cancelled) }
        guard result.jobID == job.id else {
            return ModelJobResult(jobID: job.id, status: .failed, failure: .internalError)
        }
        return result
    }
}

/// Warming the model when the panel opens (#209).
extension CoreEngine {
    /// Runs a one-token job so ModelService loads the model; it stays loaded for a while after use. The job carries
    /// the chat instructions and the conversation so far, which ModelService then keeps read for the first
    /// question (#52).
    func prepareModel() -> CoreResponse {
        // While a brief is being written the model is loading anyway; the extra one-token job waits its turn.
        let id = "warm-" + UUID().uuidString.lowercased()
        let now = clock()
        guard let job = try? ModelJob(
            id: id, model: options.modelName, system: Chat.systemPrompt(personality), user: "OK", maxTokens: 1,
            deadline: now.addingTimeInterval(60), inputRevision: "warm-up",
            history: now.timeIntervalSince(conversationAt) > Chat.memory ? [] : chatHistory
        ), job.validate().isEmpty else { return .refused(code: "unavailable") }
        Task {
            await self.acquire()
            _ = try? await self.model.run(job)
            self.release()
        }
        return .accepted(jobID: id)
    }

    /// The tune-up (ADR-0030): a fixed synthetic job, no owner data, timed by the model service.
    func tuneUp() async -> CoreResponse {
        let now = clock()
        let job = ModelJob(
            id: "tune-up-" + UUID().uuidString.lowercased(), model: options.modelName,
            system: "You are a helpful assistant. Answer in plain sentences.",
            user: "In about 150 words, explain how a lighthouse warns ships at night.", maxTokens: 200,
            deadline: now.addingTimeInterval(120), inputRevision: "tune-up"
        )
        guard job.validate().isEmpty else { return .refused(code: "unavailable") }
        await acquire()
        defer { release() }
        guard let result = try? await model.run(job) else { return .refused(code: "unavailable") }
        guard result.status == .completed else { return .refused(code: result.failure?.rawValue ?? result.status.rawValue) }
        return .tuneUp(result.metrics)
    }
}

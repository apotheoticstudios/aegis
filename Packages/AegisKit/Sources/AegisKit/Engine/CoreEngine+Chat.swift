import Foundation

/// Talking with Aegis (#194): the conversation path of the Ask bar, with notes from the owner's day.
extension CoreEngine {
    /// Room for a full answer when the owner asks for one (#52); chat stays short by the instructions.
    static let chatTokens = 1200

    /// A conversational reply from the local model. `found` holds context lines Ask's retrieval found, if any.
    func chat(_ question: String, found: [String], turn: UUID, includeNotes: Bool = true) async -> CoreResponse {
        let now = clock()
        if now.timeIntervalSince(conversationAt) > Chat.memory {
            conversation = []
        }
        let social = Chat.isSocial(question)
        let includeNotes = includeNotes && !social
        let scorer = includeNotes ? await meaningScorer(for: question) : nil
        let day = includeNotes && Chat.wantsDayContext(question) ? await dayNotes(now: now) : []
        let notes = includeNotes ? await memory.notesForChat(question, now: now, calendar: calendar, meaning: scorer) + day
            + found.prefix(30).map { "From your messages: " + $0 } : []
        let user = Chat.prepare(question, notes: notes, now: now, calendar: calendar)
        do {
            let job = try ModelJob(
                id: "chat-" + UUID().uuidString.lowercased(), model: options.modelName,
                system: Chat.systemPrompt(personality) + (social
                    ?
                    "\nThis turn is only a greeting or acknowledgement. Reply briefly to it; do not invent or bring up personal events or records." :
                    ""),
                user: user, maxTokens: min(social ? 120 : Self.chatTokens, ModelJob.maxOutputTokens),
                deadline: now.addingTimeInterval(120), inputRevision: SHA256.hex(Array(user.utf8)),
                history: social
                    ? Array(conversation.reversed().prefix { Chat.isSocial($0.owner) }.reversed()).map {
                        ModelJob.Exchange(owner: $0.owner, aegis: $0.aegis)
                    } : chatHistory, style: .conversation
            )
            guard job.validate().isEmpty else {
                return .refused(code: "too_long")
            }
            replyJob = (job.id, question)
            defer {
                if replyJob?.id == job.id {
                    replyJob = nil
                }
            }
            let result = try await runQuestionJob(job, turn: turn)
            guard result.status == .completed else {
                return .refused(code: result.failure?.rawValue ?? result.status.rawValue)
            }
            let reply = result.text.map { Chat.reply($0, owner: question, name: personality.name) } ?? Chat.fallback
            if reply != Chat.fallback, reply != Chat.cannotAct, reply != Chat.memoryNotSaved {
                remember(question, reply)
            }
            // Only the owner's words are learned from (#282); the reply may quote collected messages.
            if !Chat.isSocial(question), !FollowUpQuestion.leansOnPrevious(question) {
                queueLearning(question)
            }
            return .answer(Answer(text: reply, eventIDs: [], scheduleIDs: [], model: options.modelName, generatedAt: clock()))
        } catch {
            return .refused(code: "unavailable")
        }
    }

    /// The finished, checked sentences of the reply being written (#263), so the panel can speak while the model
    /// is still thinking; empty when there's none.
    func partialReply() async -> CoreResponse {
        guard let (id, question) = replyJob, let text = await model.partial(jobID: id) else { return .partialReply("") }
        return .partialReply(Chat.speakable(text, owner: question, name: personality.name))
    }

    /// The conversation as the model's own earlier turns (#52).
    var chatHistory: [ModelJob.Exchange] {
        conversation.map { ModelJob.Exchange(owner: $0.owner, aegis: $0.aegis) }
    }

    /// Keeps the exchange for follow-ups and, on this Mac only, in memory's past exchanges (#222).
    func remember(_ question: String, _ reply: String) {
        conversation.append(Chat.Turn(owner: question, aegis: reply))
        conversation = Chat.kept(conversation)
        conversationAt = clock()
        conversationGrounded = false
        memory.record(PastExchange(at: conversationAt, owner: question, aegis: reply))
        saveMemory()
    }

    /// What's on: the brief's items, who's waiting, open promises and the next day's schedule, one line each.
    private func dayNotes(now: Date) async -> [String] {
        var notes: [String] = []
        if let brief = try? await latestBrief()?.brief {
            let ids = Array(Set(brief.items.prefix(10).flatMap(\.eventIDs)))
            if let events = try? await store.events(ids: ids) {
                notes += await named(events).filter { !BriefLayout.plantedOrder($0) }.prefix(20).map {
                    "Source record: " + AskRetrieval.line($0, calendar: calendar)
                }
            }
        }
        if case let .people(waiting) = await people() {
            notes += waiting.prefix(5).map { "Waiting on you: \($0.person.name), \($0.questions) question(s), latest: \($0.latest)" }
        }
        if case let .commitments(open) = await commitments() {
            notes += open.prefix(3).map { "You told \($0.person) you'd: \($0.text)" }
        }
        return await notes + scheduleNotes(now: now)
    }

    private func scheduleNotes(now: Date) async -> [String] {
        let end = now.addingTimeInterval(36 * 3600)
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale.autoupdatingCurrent
        format.dateFormat = "EEE d MMM yyyy, h:mm a"
        let occurrences = await (try? store.occurrences(from: now, to: end)) ?? []
        let reminders = await (try? store.reminders(from: now.addingTimeInterval(-86400), to: end)) ?? []
        return occurrences.sorted { $0.start < $1.start }.prefix(6).map {
            "Calendar: \($0.title), starts " + format.string(from: $0.start) + ", ends " + format.string(from: $0.end)
                + ($0.isAllDay ? " (all day; end exclusive)" : "") + EventEvidence.attendees($0)
        } + reminders.filter { !$0.isCompleted }.prefix(4).map {
            "Reminder: \($0.title)" + ($0.due.map { ", due " + format.string(from: $0.date) } ?? " (no due date)")
        }
    }
}

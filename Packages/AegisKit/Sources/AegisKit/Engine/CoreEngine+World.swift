import Foundation

/// One local model job for the owner's globe request (#296) or command (ADR-0031), without conversation memory.
extension CoreEngine {
    func worldPlan(_ question: String) async -> CoreResponse {
        await planTurn(question) { asked, turn in
            await self.runPlanJob(
                "world", system: WorldActions.systemPrompt(), user: WorldActions.input(question: asked, place: nil),
                maxTokens: 300, turn: turn
            ) { text in
                WorldActions.parse(text).map { .worldPlan(actions: $0.actions, say: $0.say) }
            }
        }
    }

    func commandPlan(_ question: String, shortcuts: [String]) async -> CoreResponse {
        guard shortcuts.count <= CommandPlan.maxShortcuts,
              shortcuts.allSatisfy({ $0.unicodeScalars.count <= CommandPlan.maxNameScalars })
        else { return .refused(code: "too_long") }
        return await planTurn(question) { asked, turn in
            await self.runPlanJob(
                "command", system: CommandPlan.systemPrompt(), user: CommandPlan.input(question: asked, shortcuts: shortcuts),
                maxTokens: 120, turn: turn
            ) { .commandPlan(CommandPlan.parse($0, shortcuts: shortcuts)) }
        }
    }

    /// Takes the model from any running question, as a new question does.
    private func planTurn(_ question: String, _ run: (String, UUID) async -> CoreResponse) async -> CoreResponse {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return .refused(code: "bad_question") }
        guard asked.unicodeScalars.count <= CoreRequest.maxQuestionScalars else { return .refused(code: "too_long") }
        let turn = UUID()
        currentQuestion = turn
        await pauseLearning()
        if let job = questionJobID {
            await model.cancel(jobID: job)
        }
        guard currentQuestion == turn else { return .refused(code: "cancelled") }
        await interruptBriefForQuestion()
        await acquire()
        defer { release() }
        guard currentQuestion == turn else { return .refused(code: "cancelled") }
        return await run(asked, turn)
    }

    private func runPlanJob(
        _ kind: String, system: String, user: String, maxTokens: Int, turn: UUID, parse: (String) -> CoreResponse?
    ) async -> CoreResponse {
        let job = ModelJob(
            id: kind + "-" + UUID().uuidString.lowercased(), model: options.modelName, system: system,
            user: user, maxTokens: maxTokens, deadline: clock().addingTimeInterval(60), inputRevision: SHA256.hex(Array(user.utf8))
        )
        guard job.validate().isEmpty else { return .refused(code: "too_long") }
        do {
            let result = try await runQuestionJob(job, turn: turn)
            guard result.status == .completed else { return .refused(code: result.status.rawValue) }
            guard let text = result.text, let response = parse(text) else { return .refused(code: "invalid_plan") }
            return response
        } catch {
            return .refused(code: "unavailable")
        }
    }
}

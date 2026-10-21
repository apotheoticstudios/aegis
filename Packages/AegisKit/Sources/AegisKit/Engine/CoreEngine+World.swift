import Foundation

/// One local model job for the owner's globe request, without conversation memory (#296).
extension CoreEngine {
    func worldPlan(_ question: String) async -> CoreResponse {
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
        return await runWorldPlan(asked, turn: turn)
    }

    private func runWorldPlan(_ question: String, turn: UUID) async -> CoreResponse {
        let user = WorldActions.input(question: question, place: nil)
        let job = ModelJob(
            id: "world-" + UUID().uuidString.lowercased(), model: options.modelName, system: WorldActions.systemPrompt(),
            user: user, maxTokens: 300, deadline: clock().addingTimeInterval(60), inputRevision: SHA256.hex(Array(user.utf8))
        )
        guard job.validate().isEmpty else { return .refused(code: "too_long") }
        do {
            let result = try await runQuestionJob(job, turn: turn)
            guard result.status == .completed else { return .refused(code: result.status.rawValue) }
            guard let text = result.text, let plan = WorldActions.parse(text) else { return .refused(code: "invalid_plan") }
            return .worldPlan(actions: plan.actions, say: plan.say)
        } catch {
            return .refused(code: "unavailable")
        }
    }
}

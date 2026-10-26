import Foundation

/// The model reads what the owner wants looked up before anything is searched (ADR-0032).
extension CoreEngine {
    /// One short job over the owner's own words; nil when the model can't say (busy, cancelled, an unusable reply), so
    /// the phrase rules decide.
    func searchPlan(_ question: String, turn: UUID) async -> SearchPlan? {
        let user = SearchPlan.input(question: question, now: clock(), calendar: calendar)
        let job = ModelJob(
            id: "plan-" + UUID().uuidString.lowercased(), model: options.modelName, system: SearchPlan.systemPrompt(), user: user,
            maxTokens: 120, deadline: clock().addingTimeInterval(30), inputRevision: SHA256.hex(Array(user.utf8))
        )
        guard job.validate().isEmpty, let result = try? await runQuestionJob(job, turn: turn), result.status == .completed,
              let text = result.text
        else { return nil }
        return SearchPlan.parse(text, question: question)
    }
}

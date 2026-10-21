import Foundation

/// Handing questions to Claude or ChatGPT (#223, ADR-0017). AegisCore only decides, with the deterministic gate in
/// `CloudHandOff`; the panel makes the call. Nothing personal is ever handed off.
extension CoreEngine {
    /// The question to answer on the Mac (and a note to say first), or the hand-off or message that replaces it.
    func handOff(
        _ question: String, cloud: CloudHandOff.Availability
    ) async -> (question: String, note: String?, response: CoreResponse?) {
        guard !cloud.providers.isEmpty || CloudHandOff.named(question) != nil else { return (question, nil, nil) }
        switch await CloudHandOff.decide(question, history: conversation, available: cloud, names: contactNames()) {
        case .local:
            return (question, nil, nil)
        case let .keep(kept, note):
            return (kept, note, nil)
        case let .cloud(request):
            return (question, nil, .handOff(request))
        case let .unavailable(message):
            remember(question, message)
            return (question, nil, .answer(Answer(
                text: message, eventIDs: [], scheduleIDs: [], model: "aegis", generatedAt: clock()
            )))
        }
    }

    /// A hand-off's reply, kept like any exchange so follow-ups go to the same provider.
    func handedOff(_ question: String, reply: String, provider: CloudHandOff.Provider) -> CoreResponse {
        guard !question.isEmpty, question.unicodeScalars.count <= CoreRequest.maxQuestionScalars else {
            return .refused(code: "bad_question")
        }
        let shown = CloudHandOff.shown(reply)
        conversation.append(Chat.Turn(owner: question, aegis: shown, via: provider))
        conversation = Array(conversation.suffix(Chat.maxTurns))
        conversationAt = clock()
        memory.record(PastExchange(at: conversationAt, owner: question, aegis: shown))
        saveMemory()
        return .accepted(jobID: "handed-off")
    }

    /// The owner's contacts' names, which a hand-off must never carry.
    func contactNames() async -> Set<String> {
        let original = await contacts?.index()?.names ?? []
        return original.union(memory.senderAliases.map(\.name))
    }

    static func noted(_ response: CoreResponse, _ note: String) -> CoreResponse {
        guard case var .answer(answer) = response else { return response }
        answer.text = note + " " + answer.text
        return .answer(answer)
    }
}

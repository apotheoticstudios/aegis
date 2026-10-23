import AegisKit
import Foundation

extension BriefPresentation {
    static func askMessage(_ code: String) -> String {
        switch code {
        case "busy": "Aegis is writing your brief. Ask again in a minute."
        case "bad_question": "Try a shorter question."
        case "too_long": "That needs more than Aegis can read at once. Try narrowing it, for example to a person or a day."
        case "unreachable", "unavailable": "Aegis's background part isn't reachable right now."
        case "timedOut", "timed_out", "cancelled": "That took too long. Try again."
        case "unknown_citation", "invalid_draft", "unsafe_text": "I couldn't verify that answer against the available sources."
        case "web_no_results", "web_unavailable": "The public search didn't return usable information just now. Your private data stayed on this Mac."
        case "web_unverified": "The public search returned information, but I couldn't verify an answer from those excerpts."
        case "web_expired": "That public search was superseded or expired. Please ask again."
        case "model_missing": "My local language model isn't installed. Open setup to download it."
        case "model_corrupt": "My local language model couldn't load. It needs to be repaired in setup."
        case "out_of_memory": "There wasn't enough free memory to finish that answer."
        default: "My local language model didn't produce a usable answer. Please try again."
        }
    }
}

extension PublicLookupClient {
    @MainActor static func answer(
        _ question: String, service: any CoreService, isCurrent: () -> Bool
    ) async -> CoreResponse? {
        guard shouldSearch(question) else { return nil }
        let planned = await service.handle(.publicLookup(question: question))
        guard isCurrent(), !Task.isCancelled else { return .refused(code: "cancelled") }
        guard case let .publicLookup(plan) = planned else { return nil }
        do {
            let sources = try await PublicLookupClient().search(plan)
            guard isCurrent(), !Task.isCancelled else { return .refused(code: "cancelled") }
            return await service.handle(.answerPublic(planID: plan.id, sources: sources))
        } catch {
            return .refused(code: "web_unavailable")
        }
    }
}

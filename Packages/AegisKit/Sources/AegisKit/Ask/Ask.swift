import Foundation

/// Why a model draft for an answer can't be shown (fixed codes, never collected text).
public enum AskRejection: String, Error, Sendable {
    case invalidDraft = "invalid_draft"
    case unknownCitation = "unknown_citation"
    case tooLong = "too_long"
    case unsafeText = "unsafe_text"
}

/// What the model is given for one question: the bounded, cited context (#163).
public struct AskInput: Sendable, Equatable {
    /// The user message for the model: today's date, the question, then the context lines.
    public let text: String
    /// Event IDs in the context, in the order shown.
    public let eventIDs: [String]
    /// Schedule IDs (occurrences and reminders) in the context.
    public let scheduleIDs: [String]

    /// A deterministic clarification/not-found response; not part of the wire contract.
    var directAnswer: String?
    /// Owner explicitly requested stored evidence, even if the question starts with a greeting.
    var prefersGrounded = false

    public init(text: String, eventIDs: [String], scheduleIDs: [String]) {
        self.text = text
        self.eventIDs = eventIDs
        self.scheduleIDs = scheduleIDs
    }

    /// Nothing relevant was found: answer without the model.
    public var isEmpty: Bool {
        eventIDs.isEmpty && scheduleIDs.isEmpty
    }
}

/// Ask Aegis anything (#163): retrieval, the model's prompt, and checks on its answer. No model call
/// happens here; AegisCore runs the job on ModelService. Collected text is data, never instructions.
public enum Ask {
    /// The answer when nothing relevant was found (no model call).
    public static let notFound = "I couldn't find anything about that in your recent messages, email or calendar."

    /// The system prompt for answers.
    public static func systemPrompt() -> String {
        guard let url = Bundle.module.url(forResource: "ask-prompt", withExtension: "md"),
              let prompt = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Answer only from context DATA. Reply only with JSON {\"answer\":\"I couldn't find it.\",\"event_ids\":[],\"schedule_ids\":[]}."
        }
        return prompt
    }

    /// Finds the context for a question: words, time words ("today", "yesterday", "this week",
    /// weekdays…) and contact names matched against senders. Read-only.
    /// `plan` is the model's reading of the question (ADR-0032); without one, the phrase rules read it.
    public static func prepare(
        question: String, now: Date, calendar: Calendar, store: any EventStore, contacts: ContactIndex?, plan: SearchPlan? = nil
    ) async throws -> AskInput {
        try await AskRetrieval.prepare(question: question, now: now, calendar: calendar, store: store, contacts: contacts, plan: plan)
    }

    /// Checks a model draft against its input; only a success may be shown.
    public static func check(
        _ draft: [String: Any], input: AskInput, model: String, generatedAt: Date
    ) -> Result<Answer, AskRejection> {
        guard Set(draft.keys) == ["answer", "event_ids", "schedule_ids"],
              let text = draft["answer"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawEvents = draft["event_ids"] as? [String],
              let rawSchedule = draft["schedule_ids"] as? [String]
        else { return .failure(.invalidDraft) }
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        let events = unique(rawEvents), schedule = unique(rawSchedule)
        guard Set(events).isSubset(of: input.eventIDs), Set(schedule).isSubset(of: input.scheduleIDs) else {
            return .failure(.unknownCitation)
        }
        guard text.unicodeScalars.count <= Answer.maxTextScalars else { return .failure(.tooLong) }
        guard !EventEvidence.exposesIdentity(text) else { return .failure(.unsafeText) }
        // Raw record IDs belong in the citations, never in the text the owner reads.
        guard text.range(of: #"\b(?:ev|cal|rem|occ)_[0-9a-f]{6,}"#, options: .regularExpression) == nil else {
            return .failure(.unsafeText)
        }
        // A broad question may cite many records: the first ones stand, in the model's order.
        let cited = Array(events.prefix(Answer.maxCitations))
        let citedSchedule = Array(schedule.prefix(max(0, Answer.maxCitations - cited.count)))
        guard text.filter({ $0 == "\n" }).count < 3,
              !text.unicodeScalars.contains(where: {
                  ($0.properties.generalCategory == .control && $0.value != 10)
                      || $0.properties.generalCategory == .format || $0.value == 0x2028 || $0.value == 0x2029
              }) else { return .failure(.unsafeText) }
        if events.isEmpty, schedule.isEmpty, text != notFound, text != "I couldn't find it." {
            return .failure(.unknownCitation)
        }
        return .success(Answer(text: text, eventIDs: cited, scheduleIDs: citedSchedule, model: model, generatedAt: generatedAt))
    }
}

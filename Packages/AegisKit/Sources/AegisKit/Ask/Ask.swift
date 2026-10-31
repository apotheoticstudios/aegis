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
              let drafted = draft["answer"] as? String, !drafted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawEvents = draft["event_ids"] as? [String],
              let rawSchedule = draft["schedule_ids"] as? [String]
        else { return .failure(.invalidDraft) }
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        // Small slips are repaired rather than losing the answer: invented citations are dropped, raw record IDs
        // leave the text, extra lines join and an overlong answer ends at its last full sentence.
        let events = unique(rawEvents).filter(input.eventIDs.contains)
        let schedule = unique(rawSchedule).filter(input.scheduleIDs.contains)
        var text = drafted.replacingOccurrences(
            of: #"\s*[\[(]?\b(?:ev|cal|rem|occ)_[0-9a-f]{6,}[\])]?"#,
            with: "",
            options: .regularExpression
        )
        text = text.split(whereSeparator: { (character: Character) in character.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if text.unicodeScalars.count > Answer.maxTextScalars {
            let cut = String(String.UnicodeScalarView(text.unicodeScalars.prefix(Answer.maxTextScalars - 1)))
            text = cut.lastIndex(where: { ".!?".contains($0) }).map { String(cut[...$0]) } ?? cut + "…"
        }
        guard !text.isEmpty else { return .failure(.invalidDraft) }
        guard !EventEvidence.exposesIdentity(text) else { return .failure(.unsafeText) }
        // A broad question may cite many records: the first ones stand, in the model's order.
        let cited = Array(events.prefix(Answer.maxCitations))
        let citedSchedule = Array(schedule.prefix(max(0, Answer.maxCitations - cited.count)))
        func hidden(_ scalar: Unicode.Scalar) -> Bool {
            let category = scalar.properties.generalCategory
            return category == .control || category == .format || scalar.value == 0x2028 || scalar.value == 0x2029
        }
        guard !text.unicodeScalars.contains(where: hidden) else { return .failure(.unsafeText) }
        // Nothing real backs the answer: say so plainly rather than show claims about the owner's data.
        if events.isEmpty, schedule.isEmpty, text != notFound, text != "I couldn't find it." {
            return .success(Answer(text: notFound, eventIDs: [], scheduleIDs: [], model: model, generatedAt: generatedAt))
        }
        return .success(Answer(text: text, eventIDs: cited, scheduleIDs: citedSchedule, model: model, generatedAt: generatedAt))
    }
}

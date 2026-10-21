import Foundation

/// Conversion provenance kept outside the frozen Brief contract, before hard checks run.
public struct BriefConversion: Sendable {
    public let brief: Brief
    /// Structurally malformed items removed during conversion.
    public let droppedItems: Int
    /// Any fields beyond the model's items/text/priority/event_ids allowlist are treated as attempted actions.
    public let attemptedActions: Bool
    /// Preserve urgent citations even from malformed items so dropping cannot hide a planted order.
    let urgentEventIDs: [String]
}

/// Model-independent prompt assembly, input compatibility, and checked answer conversion.
public enum Briefing {
    /// The JSON-only answer shape appended for text models.
    public static let jsonFormat = """

    Answer with JSON only, no other text, in exactly this shape:
    {"items": [{"text": "one short sentence", "priority": "urgent", "event_ids": ["ev_0123456789abcdef"]}]}
    "priority" is one of "urgent", "reply", "fyi".

    """

    /// Canonical prompt bundled with AegisKit, plus the answer format when requested.
    public static func systemPrompt(includeJSONFormat: Bool = true) throws -> String {
        guard let url = Bundle.module.url(forResource: "prompt", withExtension: "md") else { throw PipelineError.invalidDraft }
        return try String(contentsOf: url, encoding: .utf8) + (includeJSONFormat ? jsonFormat : "")
    }

    /// Legacy full-span input: merge first and preserve original arrival order at equal timestamps.
    public static func buildInput(_ events: [Event], maxEvents: Int = 40, maxBody: Int = 280) throws -> BriefInput {
        let fallback = Date(timeIntervalSince1970: 978_307_200)
        let policy = try BriefInputPolicy(
            windowStart: events.map(\.eventTime).min() ?? fallback,
            windowEnd: events.map(\.eventTime).max() ?? fallback, maxEvents: maxEvents, maxBody: maxBody
        )
        var order: [String: Int] = [:]
        for (index, event) in events.enumerated() where order[event.id] == nil {
            order[event.id] = index
        }
        return try EventMerger.withMergedEvents(events) { try policy.build($0, inputOrder: order) }
    }

    /// First valid JSON object, ignoring thinking blocks and code fences. Braces inside strings are data.
    public static func extractJSON(_ answer: String) -> [String: Any]? {
        let text = answer.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"```(?:json)?"#, with: "", options: .regularExpression)
        let bytes = Array(text.utf8)
        for start in bytes.indices where bytes[start] == 123 {
            var depth = 0, quoted = false, escaped = false
            for end in start ..< bytes.count {
                let byte = bytes[end]
                if quoted {
                    if escaped {
                        escaped = false
                    } else if byte == 92 {
                        escaped = true
                    } else if byte == 34 {
                        quoted = false
                    }
                } else if byte == 34 {
                    quoted = true
                } else if byte == 123 {
                    depth += 1
                } else if byte == 125 {
                    depth -= 1
                    if depth == 0 {
                        if let object = try? JSONSerialization
                            .jsonObject(with: Data(bytes[start ... end])) as? [String: Any]
                        {
                            return object
                        }
                        break
                    }
                }
            }
        }
        return nil
    }

    /// Compatibility conversion only; use BriefChecks.check on the draft before publishing.
    /// Malformed items are dropped. This API discards provenance, so cannot detect stripped action fields later.
    public static func toBrief(
        _ draft: [String: Any], omitted: Int, windowStart: Date, windowEnd: Date,
        model: String, generatedAt: Date = Date()
    ) throws -> Brief {
        try convert(
            draft, omitted: omitted, windowStart: windowStart, windowEnd: windowEnd, model: model, generatedAt: generatedAt
        ).brief
    }

    /// Drop structural defects, retaining counts and evidence of disallowed fields for BriefChecks.
    /// A missing/non-array items field is a malformed draft; empty citation arrays survive for hard rejection.
    public static func convert(
        _ draft: [String: Any], omitted: Int, windowStart: Date, windowEnd: Date,
        model: String, generatedAt: Date = Date()
    ) throws -> BriefConversion {
        guard let values = draft["items"] as? [Any] else { throw PipelineError.invalidDraft }
        var items: [Brief.Item] = []
        var dropped = 0
        for value in values {
            guard let item = value as? [String: Any], let text = item["text"] as? String,
                  !text.isEmpty,
                  let rawPriority = item["priority"] as? String, let priority = Brief.Priority(rawValue: rawPriority),
                  let citations = item["event_ids"] as? [String]
            else { dropped += 1; continue }
            items.append(.init(text: text, priority: priority, eventIDs: citations))
        }
        let brief = Brief(
            generatedAt: Date(timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down)),
            windowStart: windowStart, windowEnd: windowEnd,
            model: model, items: items, omittedEvents: omitted
        )
        return BriefConversion(
            brief: brief, droppedItems: dropped,
            attemptedActions: draft.keys.contains { $0 != "items" } || containsDisallowedFields(values),
            urgentEventIDs: values.compactMap { $0 as? [String: Any] }.filter { $0["priority"] as? String == "urgent" }
                .flatMap { ($0["event_ids"] as? [Any] ?? []).compactMap { $0 as? String } }
        )
    }

    private static func containsDisallowedFields(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            let allowed: Set = ["text", "priority", "event_ids"]
            return object.keys.contains { !allowed.contains($0) } || object.values.contains(where: containsDisallowedFields)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsDisallowedFields)
        }
        return false
    }

    /// Cited events at their expected priorities (hits and total), independent of other rubric checks.
    public static func recall(_ brief: Brief, mustInclude: [String: Brief.Priority]) -> (hits: Int, total: Int) {
        let hits = mustInclude.filter { ref, priority in brief.items.contains { $0.priority == priority && $0.eventIDs.contains(ref) } }
            .count
        return (hits, mustInclude.count)
    }
}

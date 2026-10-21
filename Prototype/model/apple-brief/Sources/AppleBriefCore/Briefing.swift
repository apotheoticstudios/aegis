import Foundation

/// The parts of a contract event (`Prototype/contracts/event.schema.json`) the brief needs.
public struct Event: Decodable, Sendable, Equatable {
    public var id: String
    public var source: String
    public var sender: String?
    public var eventTime: String
    public var title: String?
    public var body: String
    public var content: String

    enum CodingKeys: String, CodingKey {
        case id, source, sender, title, body, content
        case eventTime = "event_time"
    }

    public init(id: String, source: String, sender: String?, eventTime: String, title: String?, body: String, content: String) {
        self.id = id
        self.source = source
        self.sender = sender
        self.eventTime = eventTime
        self.title = title
        self.body = body
        self.content = content
    }
}

/// How much of the window the model gets: the newest events first, each body cut to a limit, so a
/// busy day can't overflow a small model's context. What's left out is counted, never hidden.
public struct InputPolicy: Sendable {
    public var maxEvents: Int
    public var maxBodyCharacters: Int

    public init(maxEvents: Int = 40, maxBodyCharacters: Int = 280) {
        self.maxEvents = maxEvents
        self.maxBodyCharacters = maxBodyCharacters
    }
}

/// Text on one line: line breaks and other control characters become spaces.
public func oneLine(_ text: String) -> String {
    String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
}

/// Text as a JSON string literal, so quotes and line breaks are escaped.
public func quoted(_ text: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    guard let data = try? encoder.encode(text), let literal = String(data: data, encoding: .utf8) else {
        return "\"\(oneLine(text))\""
    }
    return literal
}

public struct ModelInput: Sendable, Equatable {
    public var text: String
    public var includedIDs: [String]
    public var omitted: Int
}

public enum Briefing {
    /// Events from JSON Lines text (blank lines ignored).
    public static func events(fromJSONLines text: String) throws -> [Event] {
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(Event.self, from: Data($0.utf8)) }
    }

    /// One line per event, oldest first, each starting with its id in square brackets.
    public static func input(for events: [Event], policy: InputPolicy = InputPolicy()) -> ModelInput {
        let newestFirst = events.sorted { $0.eventTime > $1.eventTime }
        let kept = Array(newestFirst.prefix(policy.maxEvents)).sorted { $0.eventTime < $1.eventTime }
        let lines = kept.map { event -> String in
            // Collected text can't break out of its line: names are flattened to one line and the
            // body is a JSON string literal (quotes and newlines escaped), so a message can never
            // fake another event line or a citation.
            var line = "[\(event.id)] \(event.eventTime) · \(event.source)"
            if let sender = event.sender {
                line += " · from \(oneLine(sender))"
            }
            if let title = event.title, title != event.sender {
                line += " · \(oneLine(title))"
            }
            let body = event.body.count > policy.maxBodyCharacters
                ? String(event.body.prefix(policy.maxBodyCharacters)) + "…"
                : event.body
            line += body.isEmpty ? " · (no text: \(event.content))" : " · \(quoted(body))"
            return line
        }
        return ModelInput(
            text: "Events:\n" + lines.joined(separator: "\n"),
            includedIDs: kept.map(\.id),
            omitted: events.count - kept.count
        )
    }
}

/// One brief item as the contract spells it.
public struct BriefItemRecord: Encodable, Sendable, Equatable {
    public var text: String
    public var priority: String
    public var eventIDs: [String]

    enum CodingKeys: String, CodingKey {
        case text, priority
        case eventIDs = "event_ids"
    }

    public init(text: String, priority: String, eventIDs: [String]) {
        self.text = text
        self.priority = priority
        self.eventIDs = eventIDs
    }
}

/// A brief in the contract's format (`Prototype/contracts/brief.schema.json`).
public struct BriefRecord: Encodable, Sendable, Equatable {
    public var schemaVersion = "0.1"
    public var generatedAt: String
    public var windowStart: String
    public var windowEnd: String
    public var model: String
    public var items: [BriefItemRecord]
    public var omittedEvents: Int

    enum CodingKeys: String, CodingKey {
        case model, items
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case omittedEvents = "omitted_events"
    }

    public init(generatedAt: String, windowStart: String, windowEnd: String, model: String, items: [BriefItemRecord], omittedEvents: Int) {
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.model = model
        self.items = items
        self.omittedEvents = omittedEvents
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

import Foundation

// swiftlint:disable nesting
// The types nest the way the contract's JSON does (Event › Observation › Route).

/// A brief written from events: short items, each with a priority and the events it cites. Data contract
/// v0.1 (`Prototype/contracts/brief.schema.json`). A brief can hold no actions or tool calls.
public struct Brief: Codable, Sendable, Hashable {
    /// The contract version this type reads and writes.
    public static let schemaVersion = "0.1"

    /// How soon an item needs the owner.
    public enum Priority: String, Codable, Sendable, CaseIterable {
        /// Needs attention today.
        case urgent
        /// Someone is waiting for an answer.
        case reply
        /// Worth knowing.
        case fyi
    }

    /// The one person, or group chat, an item is about, so the panel can group their items (#158, additive).
    /// Set by Aegis from the cited events' senders, never by the model.
    public struct Person: Codable, Sendable, Hashable {
        /// A stable key: "contact:<Contacts ID>", "handle:<sender handle>" or "group:<chat ID>".
        public var id: String
        /// The name to show: the contact's name, or the handle.
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One line of the brief.
    public struct Item: Codable, Sendable, Hashable {
        public var text: String
        public var priority: Priority
        /// The events this item is based on (at least one, no repeats).
        public var eventIDs: [String]
        /// The person all its events came from, when there is exactly one.
        public var person: Person?

        public init(text: String, priority: Priority, eventIDs: [String], person: Person? = nil) {
            self.text = text
            self.priority = priority
            self.eventIDs = eventIDs
            self.person = person
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case text, priority, person
            case eventIDs = "event_ids"
        }

        func schemaErrors(at path: String) -> [String] {
            var errors: [String] = []
            if text.isEmpty {
                errors.append("\(path)/text: shorter than 1")
            }
            if eventIDs.isEmpty {
                errors.append("\(path)/event_ids: needs at least 1 item(s)")
            }
            if Set(eventIDs).count != eventIDs.count {
                errors.append("\(path)/event_ids: items must be unique")
            }
            if let person, person.id.isEmpty || person.name.isEmpty || person.name.unicodeScalars.count > 200
                || person.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            {
                errors.append("\(path)/person: needs a non-empty id and a name of 1 to 200 printable characters")
            }
            for (position, ref) in eventIDs.enumerated() where !EventID.isWellFormed(ref) {
                errors.append("\(path)/event_ids/\(position): does not match ^ev_[0-9a-f]{16}$")
            }
            return errors
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            priority = try container.decode(Priority.self, forKey: .priority)
            eventIDs = try container.decode([String].self, forKey: .eventIDs)
            person = try container.decodeIfPresent(Person.self, forKey: .person)
        }
    }

    public var schemaVersion: String
    public var generatedAt: Date
    public var windowStart: Date
    public var windowEnd: Date
    /// Which model wrote it (optional).
    public var model: String?
    public var items: [Item]
    /// Events in the window that weren't given to the model.
    public var omittedEvents: Int

    public init(generatedAt: Date, windowStart: Date, windowEnd: Date, model: String?, items: [Item], omittedEvents: Int) {
        schemaVersion = Brief.schemaVersion
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.model = model
        self.items = items
        self.omittedEvents = omittedEvents
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case model, items
        case omittedEvents = "omitted_events"
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        generatedAt = try decodeTime(container, .generatedAt)
        windowStart = try decodeTime(container, .windowStart)
        windowEnd = try decodeTime(container, .windowEnd)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        items = try container.decode([Item].self, forKey: .items)
        omittedEvents = try container.decode(Int.self, forKey: .omittedEvents)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(ContractTime.format(generatedAt), forKey: .generatedAt)
        try container.encode(ContractTime.format(windowStart), forKey: .windowStart)
        try container.encode(ContractTime.format(windowEnd), forKey: .windowEnd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(items, forKey: .items)
        try container.encode(omittedEvents, forKey: .omittedEvents)
    }

    /// Contract errors as "path: message" (empty when valid), the same rules as Stage 0's `validate_brief`:
    /// the schema's constraints, every cited event among `knownEventIDs`, and a window that runs forwards.
    public func validate(knownEventIDs: Set<String>) -> [String] {
        var errors: [String] = []
        if schemaVersion != Brief.schemaVersion {
            errors.append("/schema_version: must be \(Brief.schemaVersion)")
        }
        if omittedEvents < 0 {
            errors.append("/omitted_events: below 0")
        }
        for (index, item) in items.enumerated() {
            errors += item.schemaErrors(at: "/items/\(index)")
        }
        guard errors.isEmpty else { return errors }
        for (index, item) in items.enumerated() {
            for ref in item.eventIDs where !knownEventIDs.contains(ref) {
                errors.append("/items/\(index)/event_ids: unknown event \(ref)")
            }
        }
        if windowStart > windowEnd {
            errors.append("/window_start: after window_end")
        }
        return errors
    }
}

// swiftlint:enable nesting

import Foundation

// swiftlint:disable nesting
// The types nest the way the contract's JSON does (Event › Observation › Route).

/// One thing that arrived on the Mac (a notification, message or email): Aegis's normalized event.
///
/// Data contract v0.2 (#63): v0.1 (`Prototype/contracts/event.schema.json`, Stage 0) plus who the message is
/// between: `direction`, the raw `senderHandle` and `recipients`, and the Contacts match kept separately
/// in `senderContact`, so a name mentioned in the text can never become the sender. v0.1 documents are
/// still read, through ``migrate(fromV01:)``.
///
/// Collected text is data, never instructions. Merged duplicates keep every route that saw them in
/// `observations`.
public struct Event: Codable, Sendable, Hashable, Identifiable {
    /// The contract version this type writes.
    public static let schemaVersion = "0.2"
    /// The versions this type reads.
    public static let readableVersions: Set<String> = ["0.1", "0.2"]

    /// Where the event's own record lives.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case notification, imessage, sms, email

        /// The capture routes that can produce this source's own record.
        public var routes: Set<Observation.Route> {
            switch self {
            case .notification: [.notificationDB, .accessibility]
            case .imessage, .sms: [.chatDB]
            case .email: [.mailStore]
            }
        }
    }

    /// Which clock `eventTime` comes from.
    public enum TimeSource: String, Codable, Sendable, CaseIterable {
        case delivered, sent, received, header
    }

    /// How much of the original text `body` holds.
    public enum Content: String, Codable, Sendable, CaseIterable {
        case complete, preview, redacted, unavailable
    }

    /// Facts about the record that matter when reading it.
    public enum Flag: String, Codable, Sendable, CaseIterable {
        case truncated
        case clockSkew = "clock_skew"
        case encrypted, edited
        case attachmentOnly = "attachment_only"
        /// The sender's handle matched more than one contact, so no name was chosen (v0.2).
        case ambiguousSender = "ambiguous_sender"
        /// Bulk or marketing email: List-Unsubscribe, List-Id or Precedence bulk/list/junk (v0.2 addition, #151).
        case bulk
    }

    /// Whether the owner received or sent it (v0.2).
    public enum Direction: String, Codable, Sendable, CaseIterable {
        case incoming, outgoing, unknown
    }

    /// The single Contacts card a sender's handle matched (v0.2). Resolved from the handle, never from text.
    public struct ContactRef: Codable, Sendable, Hashable {
        /// The contact's identifier in the Contacts store.
        public var id: String
        /// The name to show for it.
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One route that saw this event, with that route's own record ID.
    public struct Observation: Codable, Sendable, Hashable {
        /// A capture route.
        public enum Route: String, Codable, Sendable, CaseIterable {
            case notificationDB = "notification_db"
            case accessibility
            case chatDB = "chat_db"
            case mailStore = "mail_store"
        }

        public var route: Route
        public var sourceRecordID: String
        public var captureTime: Date

        public init(route: Route, sourceRecordID: String, captureTime: Date) {
            self.route = route
            self.sourceRecordID = sourceRecordID
            self.captureTime = captureTime
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case route
            case sourceRecordID = "source_record_id"
            case captureTime = "capture_time"
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            route = try container.decode(Route.self, forKey: .route)
            sourceRecordID = try container.decode(String.self, forKey: .sourceRecordID)
            captureTime = try decodeTime(container, .captureTime)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(route, forKey: .route)
            try container.encode(sourceRecordID, forKey: .sourceRecordID)
            try container.encode(ContractTime.format(captureTime), forKey: .captureTime)
        }
    }

    public var schemaVersion: String
    /// `EventID.make(source:sourceRecordID:)`, so the same record always gets the same ID.
    public var id: String
    public var source: Source
    /// The record's ID in its own store (a GUID or message ID; never a bare row number).
    public var sourceRecordID: String
    public var appID: String?
    /// Who sent it as the source shows it: a handle, a display name, or "me" for the owner's own messages.
    public var sender: String?
    /// Received, sent or unknown (v0.2).
    public var direction: Direction
    /// The sender's raw address (phone number or email) when the source has one (v0.2).
    public var senderHandle: String?
    /// Raw addresses of the other people on a message, where the source lists them (v0.2).
    public var recipients: [String]
    /// The Contacts card the sender's handle matched; nil when none or several did (v0.2).
    public var senderContact: ContactRef?
    public var threadID: String?
    public var eventTime: Date
    public var eventTimeSource: TimeSource
    public var captureTime: Date
    public var title: String?
    /// The text as collected (data, never instructions).
    public var body: String
    public var content: Content
    public var flags: [Flag]
    public var observations: [Observation]

    /// A new event; the ID is derived from the source and record ID. `direction` defaults to outgoing when
    /// `sender` is "me" and incoming otherwise.
    public init(
        source: Source, sourceRecordID: String, appID: String?, sender: String?, threadID: String?,
        eventTime: Date, eventTimeSource: TimeSource, captureTime: Date, title: String?, body: String,
        content: Content, flags: [Flag] = [], observations: [Observation],
        direction: Direction? = nil, senderHandle: String? = nil, recipients: [String] = [], senderContact: ContactRef? = nil
    ) {
        schemaVersion = Event.schemaVersion
        id = EventID.make(source: source, sourceRecordID: sourceRecordID)
        self.source = source
        self.sourceRecordID = sourceRecordID
        self.appID = appID
        self.sender = sender
        self.direction = direction ?? (sender == "me" ? .outgoing : .incoming)
        self.senderHandle = senderHandle
        self.recipients = recipients
        self.senderContact = senderContact
        self.threadID = threadID
        self.eventTime = eventTime
        self.eventTimeSource = eventTimeSource
        self.captureTime = captureTime
        self.title = title
        self.body = body
        self.content = content
        self.flags = flags
        self.observations = observations
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case id, source
        case sourceRecordID = "source_record_id"
        case appID = "app_id"
        case sender
        case threadID = "thread_id"
        case eventTime = "event_time"
        case eventTimeSource = "event_time_source"
        case captureTime = "capture_time"
        case title, body, content, flags, observations
        case direction
        case senderHandle = "sender_handle"
        case recipients
        case senderContact = "sender_contact"

        /// The keys a v0.1 document has.
        static let v01: [CodingKeys] = allCases.filter { ![.direction, .senderHandle, .recipients, .senderContact].contains($0) }
    }

    /// Strict, like the schema: every key of the document's version must be present (nullable ones as null),
    /// and no others. A v0.1 document is migrated to v0.2 as it's read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .schemaVersion)
        guard Event.readableVersions.contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container, debugDescription: "unsupported event schema version \(version)"
            )
        }
        let keys = version == "0.1" ? CodingKeys.v01 : CodingKeys.allCases
        try rejectUnknownKeys(decoder, known: keys.map(\.rawValue))
        schemaVersion = Event.schemaVersion
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(Source.self, forKey: .source)
        sourceRecordID = try container.decode(String.self, forKey: .sourceRecordID)
        appID = try container.decode(String?.self, forKey: .appID)
        sender = try container.decode(String?.self, forKey: .sender)
        threadID = try container.decode(String?.self, forKey: .threadID)
        eventTime = try decodeTime(container, .eventTime)
        eventTimeSource = try container.decode(TimeSource.self, forKey: .eventTimeSource)
        captureTime = try decodeTime(container, .captureTime)
        title = try container.decode(String?.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        content = try container.decode(Content.self, forKey: .content)
        flags = try container.decode([Flag].self, forKey: .flags)
        observations = try container.decode([Observation].self, forKey: .observations)
        if version == "0.1" {
            (direction, senderHandle, recipients, senderContact) = (.incoming, nil, [], nil)
            self = migrate(fromV01: self)
        } else {
            direction = try container.decode(Direction.self, forKey: .direction)
            senderHandle = try container.decode(String?.self, forKey: .senderHandle)
            recipients = try container.decode([String].self, forKey: .recipients)
            senderContact = try container.decode(ContactRef?.self, forKey: .senderContact)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(sourceRecordID, forKey: .sourceRecordID)
        try container.encode(appID, forKey: .appID)
        try container.encode(sender, forKey: .sender)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(ContractTime.format(eventTime), forKey: .eventTime)
        try container.encode(eventTimeSource, forKey: .eventTimeSource)
        try container.encode(ContractTime.format(captureTime), forKey: .captureTime)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(content, forKey: .content)
        try container.encode(flags, forKey: .flags)
        try container.encode(observations, forKey: .observations)
        try container.encode(direction, forKey: .direction)
        try container.encode(senderHandle, forKey: .senderHandle)
        try container.encode(recipients, forKey: .recipients)
        try container.encode(senderContact, forKey: .senderContact)
    }

    /// Contract errors as "path: message" (empty when valid), the same rules as Stage 0's `validate_event`:
    /// the schema's constraints, the ID derived from the source record, and one observation that is the
    /// event's own record from a matching route.
    public func validate() -> [String] {
        var errors: [String] = []
        if schemaVersion != Event.schemaVersion {
            errors.append("/schema_version: must be \(Event.schemaVersion)")
        }
        if !EventID.isWellFormed(id) {
            errors.append("/id: does not match ^ev_[0-9a-f]{16}$")
        }
        errors += recordIDErrors(sourceRecordID, at: "/source_record_id")
        if Set(flags).count != flags.count {
            errors.append("/flags: items must be unique")
        }
        if observations.isEmpty {
            errors.append("/observations: needs at least 1 item(s)")
        }
        errors += partyErrors()
        for (index, observation) in observations.enumerated() {
            errors += recordIDErrors(observation.sourceRecordID, at: "/observations/\(index)/source_record_id")
        }
        guard errors.isEmpty else { return errors }
        if id != EventID.make(source: source, sourceRecordID: sourceRecordID) {
            errors.append("/id: does not match event_id(source, source_record_id)")
        }
        if !observations.contains(where: { $0.sourceRecordID == sourceRecordID && source.routes.contains($0.route) }) {
            errors.append("/observations: none is the event's own source record from a matching route")
        }
        return errors
    }
}

/// Stable event IDs: `ev_` + the first 16 hex digits of SHA-256 over `source`, U+001F, `sourceRecordID`.
/// Identical to Stage 0's `event_id`.
public enum EventID {
    /// The ID for a source record.
    public static func make(source: Event.Source, sourceRecordID: String) -> String {
        "ev_" + SHA256.hex(Array("\(source.rawValue)\u{1F}\(sourceRecordID)".utf8)).prefix(16)
    }

    /// Whether `text` has the shape of an event ID.
    public static func isWellFormed(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 19 && text.hasPrefix("ev_")
            && bytes[3...].allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }
}

/// A record ID must be non-empty and never a bare (signed) number, so a row number can't pose as an ID.
private func recordIDErrors(_ value: String, at path: String) -> [String] {
    if value.isEmpty {
        return ["\(path): shorter than 1"]
    }
    let digits = value.first == "+" || value.first == "-" ? value.dropFirst() : Substring(value)
    if !digits.isEmpty, digits.allSatisfy(\.isASCIINumber) {
        return ["\(path): must not be a bare number"]
    }
    return []
}

private extension Character {
    var isASCIINumber: Bool {
        isASCII && isNumber
    }
}

/// A coding key for any string, used to spot fields the contract doesn't allow.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

/// Throws when the object has a key outside `known` (the schema's `additionalProperties: false`).
func rejectUnknownKeys(_ decoder: any Decoder, known: [String]) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    if let extra = container.allKeys.first(where: { !known.contains($0.stringValue) }) {
        throw DecodingError.dataCorruptedError(
            forKey: extra, in: container, debugDescription: "unexpected field \(extra.stringValue)"
        )
    }
}

/// Reads a contract timestamp, failing with a decoding error when it has the wrong shape.
func decodeTime<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> Date {
    let text = try container.decode(String.self, forKey: key)
    guard let date = ContractTime.parse(text) else {
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not a contract timestamp")
    }
    return date
}

// swiftlint:enable nesting

import Foundation

// swiftlint:disable nesting
// The types nest the way the contract's JSON does (CalendarOccurrence › Status).

/// One occurrence of a calendar event, read from EventKit (contract v0.2, #63). The brief shows today's
/// schedule straight from these records, so times and states are exact and never paraphrased by the model.
public struct CalendarOccurrence: Codable, Sendable, Hashable, Identifiable {
    /// The contract version this type reads and writes.
    public static let schemaVersion = "0.2"

    /// The occurrence's state in the calendar.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case none, confirmed, tentative, cancelled
    }

    public var schemaVersion: String
    /// `ScheduleID.occurrence(itemID:occurrenceDate:)`: stays the same when the occurrence is moved.
    public var id: String
    /// The calendar item's own identifier in EventKit; every occurrence of a repeating item shares it.
    public var itemID: String
    /// When this occurrence was originally scheduled in its repeating series (EventKit's `occurrenceDate`),
    /// which doesn't change when this one occurrence is moved; nil for an event that doesn't repeat.
    /// Floating (all-day) dates come from `ScheduleID.floatingOccurrenceDate(_:in:)`, so travel can't change them.
    public var occurrenceDate: Date?
    public var calendarTitle: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// IANA time zone; nil for floating times.
    public var timeZone: String?
    public var location: String?
    public var status: Status
    public var captureTime: Date
    /// Who's invited (#184), as EventKit lists them; nil when the event has no attendee list or it wasn't read.
    /// Additive: absent from the JSON when nil, so earlier records and fixtures are unchanged.
    public var attendees: [CalendarAttendee]?
    /// Where it is, when its location was picked from Maps (#265): EventKit's own coordinates, read on the Mac,
    /// never looked up online. Additive: absent from the JSON when nil.
    public var coordinate: Coordinate?

    /// A point on the Earth, in degrees.
    public struct Coordinate: Codable, Sendable, Hashable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public init(
        itemID: String, occurrenceDate: Date?, calendarTitle: String?, title: String, start: Date, end: Date,
        isAllDay: Bool, timeZone: String?, location: String?, status: Status, captureTime: Date,
        attendees: [CalendarAttendee]? = nil, coordinate: Coordinate? = nil
    ) {
        schemaVersion = CalendarOccurrence.schemaVersion
        id = ScheduleID.occurrence(itemID: itemID, occurrenceDate: occurrenceDate)
        self.itemID = itemID
        self.occurrenceDate = occurrenceDate
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.location = location
        self.status = status
        self.captureTime = captureTime
        self.attendees = attendees
        self.coordinate = coordinate
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case id
        case itemID = "item_id"
        case occurrenceDate = "occurrence_date"
        case calendarTitle = "calendar_title"
        case title, start, end
        case isAllDay = "is_all_day"
        case timeZone = "time_zone"
        case location, status
        case captureTime = "capture_time"
        case attendees, coordinate
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        itemID = try container.decode(String.self, forKey: .itemID)
        occurrenceDate = try container.decodeNil(forKey: .occurrenceDate) ? nil : decodeTime(container, .occurrenceDate)
        calendarTitle = try container.decode(String?.self, forKey: .calendarTitle)
        title = try container.decode(String.self, forKey: .title)
        start = try decodeTime(container, .start)
        end = try decodeTime(container, .end)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        timeZone = try container.decode(String?.self, forKey: .timeZone)
        location = try container.decode(String?.self, forKey: .location)
        status = try container.decode(Status.self, forKey: .status)
        captureTime = try decodeTime(container, .captureTime)
        attendees = try container.decodeIfPresent([CalendarAttendee].self, forKey: .attendees)
        coordinate = try container.decodeIfPresent(Coordinate.self, forKey: .coordinate)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(occurrenceDate.map(ContractTime.format), forKey: .occurrenceDate)
        try container.encode(calendarTitle, forKey: .calendarTitle)
        try container.encode(title, forKey: .title)
        try container.encode(ContractTime.format(start), forKey: .start)
        try container.encode(ContractTime.format(end), forKey: .end)
        try container.encode(isAllDay, forKey: .isAllDay)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(location, forKey: .location)
        try container.encode(status, forKey: .status)
        try container.encode(ContractTime.format(captureTime), forKey: .captureTime)
        try container.encodeIfPresent(attendees, forKey: .attendees)
        try container.encodeIfPresent(coordinate, forKey: .coordinate)
    }

    /// Contract errors as "path: message" (empty when valid).
    public func validate() -> [String] {
        var errors: [String] = []
        if schemaVersion != CalendarOccurrence.schemaVersion {
            errors.append("/schema_version: must be \(CalendarOccurrence.schemaVersion)")
        }
        if itemID.isEmpty {
            errors.append("/item_id: shorter than 1")
        } else if id != ScheduleID.occurrence(itemID: itemID, occurrenceDate: occurrenceDate) {
            errors.append("/id: does not match occurrence(item_id, occurrence_date)")
        }
        if end < start {
            errors.append("/end: before start")
        }
        if timeZone?.isEmpty == true {
            errors.append("/time_zone: shorter than 1")
        }
        return errors
    }
}

/// Someone invited to a calendar event (#184), as EventKit lists them. Identity comes from the invitation's
/// address and name, never from message text.
public struct CalendarAttendee: Codable, Sendable, Hashable {
    public var name: String?
    /// The invitation's email address (from its `mailto:` URL), lower-cased; nil when it has none.
    public var email: String?
    /// True for the owner's own entry, which meeting prep leaves out.
    public var isOwner: Bool

    public init(name: String?, email: String?, isOwner: Bool) {
        self.name = name
        self.email = email
        self.isOwner = isOwner
    }

    enum CodingKeys: String, CodingKey {
        case name, email
        case isOwner = "is_owner"
    }
}

/// A reminder, read from EventKit (contract v0.2, #63). Due-today, overdue and completed states come from
/// these records, not from the model.
public struct ReminderItem: Codable, Sendable, Hashable, Identifiable {
    /// The contract version this type reads and writes.
    public static let schemaVersion = "0.2"

    /// When it's due. A date-only reminder keeps `hasTime` false, and its `date` is that day's start in `timeZone`.
    public struct Due: Codable, Sendable, Hashable {
        public var date: Date
        public var hasTime: Bool
        public var timeZone: String?

        public init(date: Date, hasTime: Bool, timeZone: String?) {
            self.date = date
            self.hasTime = hasTime
            self.timeZone = timeZone
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case date
            case hasTime = "has_time"
            case timeZone = "time_zone"
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try decodeTime(container, .date)
            hasTime = try container.decode(Bool.self, forKey: .hasTime)
            timeZone = try container.decode(String?.self, forKey: .timeZone)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ContractTime.format(date), forKey: .date)
            try container.encode(hasTime, forKey: .hasTime)
            try container.encode(timeZone, forKey: .timeZone)
        }
    }

    public var schemaVersion: String
    /// `ScheduleID.reminder(itemID:)`.
    public var id: String
    /// The reminder's own identifier in EventKit.
    public var itemID: String
    public var listTitle: String?
    public var title: String
    public var due: Due?
    public var isCompleted: Bool
    public var completedAt: Date?
    /// EventKit's priority: 0 none, 1 highest to 9 lowest.
    public var priority: Int
    public var captureTime: Date

    public init(
        itemID: String, listTitle: String?, title: String, due: Due?, isCompleted: Bool, completedAt: Date?,
        priority: Int, captureTime: Date
    ) {
        schemaVersion = ReminderItem.schemaVersion
        id = ScheduleID.reminder(itemID: itemID)
        self.itemID = itemID
        self.listTitle = listTitle
        self.title = title
        self.due = due
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.priority = priority
        self.captureTime = captureTime
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case id
        case itemID = "item_id"
        case listTitle = "list_title"
        case title, due
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
        case priority
        case captureTime = "capture_time"
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        itemID = try container.decode(String.self, forKey: .itemID)
        listTitle = try container.decode(String?.self, forKey: .listTitle)
        title = try container.decode(String.self, forKey: .title)
        due = try container.decode(Due?.self, forKey: .due)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        completedAt = try container.decode(String?.self, forKey: .completedAt).map {
            guard let date = ContractTime.parse($0) else {
                throw DecodingError.dataCorruptedError(forKey: .completedAt, in: container, debugDescription: "not a contract timestamp")
            }
            return date
        }
        priority = try container.decode(Int.self, forKey: .priority)
        captureTime = try decodeTime(container, .captureTime)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(listTitle, forKey: .listTitle)
        try container.encode(title, forKey: .title)
        try container.encode(due, forKey: .due)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encode(completedAt.map(ContractTime.format), forKey: .completedAt)
        try container.encode(priority, forKey: .priority)
        try container.encode(ContractTime.format(captureTime), forKey: .captureTime)
    }

    /// Contract errors as "path: message" (empty when valid).
    public func validate() -> [String] {
        var errors: [String] = []
        if schemaVersion != ReminderItem.schemaVersion {
            errors.append("/schema_version: must be \(ReminderItem.schemaVersion)")
        }
        if itemID.isEmpty {
            errors.append("/item_id: shorter than 1")
        } else if id != ScheduleID.reminder(itemID: itemID) {
            errors.append("/id: does not match reminder(item_id)")
        }
        if !(0 ... 9).contains(priority) {
            errors.append("/priority: must be 0 to 9")
        }
        if !isCompleted, completedAt != nil {
            errors.append("/completed_at: must be null while not completed")
        }
        return errors
    }
}

/// Stable IDs for schedule records, built like `EventID`: a prefix plus 16 hex digits of SHA-256.
public enum ScheduleID {
    /// A calendar occurrence: its item alone for a single event, or its item plus its original occurrence
    /// date in a repeating series. Moving one occurrence, or a single event, keeps its ID (DeepSeek, #53).
    public static func occurrence(itemID: String, occurrenceDate: Date?) -> String {
        let key = occurrenceDate.map { "\(itemID)\u{1F}\(ContractTime.format($0))" } ?? itemID
        return "cal_" + SHA256.hex(Array(key.utf8)).prefix(16)
    }

    /// The occurrence date to store for a floating (all-day) occurrence. EventKit reports floating dates in the
    /// Mac's current time zone, so the same occurrence is a different instant after travel. This keeps its
    /// wall-clock date and time but reads them as UTC, which gives the same value in every zone.
    public static func floatingOccurrenceDate(_ date: Date, in zone: TimeZone) -> Date {
        date.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: date)))
    }

    /// A reminder.
    public static func reminder(itemID: String) -> String {
        "rem_" + SHA256.hex(Array(itemID.utf8)).prefix(16)
    }
}

// swiftlint:enable nesting

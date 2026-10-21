import Foundation

/// The answer to a question asked in the panel (#163). Its text comes from the model, checked against the
/// exact events and schedule records it was given; every citation is one of them.
public struct Answer: Codable, Sendable, Hashable {
    /// One or a few short sentences; or a fixed "nothing found" sentence when nothing matched.
    public var text: String
    /// Messages, emails and notifications it is based on (event IDs), most relevant first.
    public var eventIDs: [String]
    /// Calendar occurrences and reminders it is based on (ScheduleIDs).
    public var scheduleIDs: [String]
    /// Which model wrote it; nil when no model was needed (nothing found).
    public var model: String?
    public var generatedAt: Date

    public static let maxTextScalars = 1200
    public static let maxCitations = 10

    public init(text: String, eventIDs: [String], scheduleIDs: [String], model: String?, generatedAt: Date) {
        self.text = text
        self.eventIDs = eventIDs
        self.scheduleIDs = scheduleIDs
        self.model = model
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case text, model
        case eventIDs = "event_ids"
        case scheduleIDs = "schedule_ids"
        case generatedAt = "generated_at"
    }

    /// Contract errors (empty when valid).
    public func validate() -> [String] {
        var errors: [String] = []
        if text.isEmpty || text.unicodeScalars.count > Self.maxTextScalars {
            errors.append("text: 1 to \(Self.maxTextScalars) characters")
        }
        if eventIDs.count + scheduleIDs.count > Self.maxCitations {
            errors.append("citations: at most \(Self.maxCitations)")
        }
        if Set(eventIDs).count != eventIDs.count || Set(scheduleIDs).count != scheduleIDs.count {
            errors.append("citations: must be unique")
        }
        if !eventIDs.allSatisfy(EventID.isWellFormed) {
            errors.append("event_ids: malformed")
        }
        return errors
    }
}

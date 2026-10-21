import Foundation

/// Additive, read-only contract (#182): something the owner promised in their own message or email.
/// Dates use the same IPC coding as `ReplyDraft`; collected promises never trigger actions.
public struct Commitment: Codable, Sendable, Hashable {
    /// A contact:, group: or handle: identity, matching `Brief.Person`; nil when unknown.
    public var personID: String?
    /// The recipient's contact name, group name or raw handle; "someone" when unknown.
    public var person: String
    /// The owner's promise sentence, on one line, at most 160 characters ("…" when cut).
    public var text: String
    /// When it is due, from the owner's words; nil when no time was given.
    public var due: Date?
    /// When the owner wrote it.
    public var madeAt: Date
    /// The message or email it came from.
    public var eventID: String

    public init(personID: String?, person: String, text: String, due: Date?, madeAt: Date, eventID: String) {
        self.personID = personID
        self.person = person
        self.text = text
        self.due = due
        self.madeAt = madeAt
        self.eventID = eventID
    }

    enum CodingKeys: String, CodingKey {
        case person, text, due
        case personID = "person_id"
        case madeAt = "made_at"
        case eventID = "event_id"
    }
}

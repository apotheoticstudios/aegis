import Foundation

/// Someone, or a group chat, waiting on the owner (#165): questions they asked that the owner hasn't
/// replied to since. Worked out from the owner's own messages on the Mac, without the model.
public struct PersonWaiting: Codable, Sendable, Hashable {
    public var person: Brief.Person
    /// When their oldest open question arrived.
    public var waitingSince: Date
    /// How many open questions they have.
    public var questions: Int
    /// The newest open question, one line, at most 140 characters.
    public var latest: String
    /// The open questions, newest first (at most 10).
    public var eventIDs: [String]

    public init(person: Brief.Person, waitingSince: Date, questions: Int, latest: String, eventIDs: [String]) {
        self.person = person
        self.waitingSince = waitingSince
        self.questions = questions
        self.latest = latest
        self.eventIDs = eventIDs
    }

    enum CodingKeys: String, CodingKey {
        case person, questions, latest
        case waitingSince = "waiting_since"
        case eventIDs = "event_ids"
    }
}

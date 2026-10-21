import Foundation

/// Something completed in the owner's local day (#211, additive, read-only). Records are data, never actions.
public struct DoneItem: Codable, Sendable, Hashable {
    /// The record-based evidence for this completion.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case answered
        case promiseKept = "promise_kept"
        case reminderCompleted = "reminder_completed"
        case eventHeld = "event_held"
    }

    public var kind: Kind
    /// A deterministic description, with message excerpts on one line.
    public var text: String
    /// When the reply, fulfilment, reminder completion or calendar ending happened.
    public var time: Date
    /// A contact:, group: or handle: identity, matching `Brief.Person`; nil when unknown.
    public var personID: String?
    /// The question or promise followed by the first answering or fulfilling message.
    public var eventIDs: [String]
    /// The completed reminder or held calendar occurrence; empty for message-based items.
    public var scheduleIDs: [String]

    public init(kind: Kind, text: String, time: Date, personID: String?, eventIDs: [String], scheduleIDs: [String]) {
        self.kind = kind
        self.text = text
        self.time = time
        self.personID = personID
        self.eventIDs = eventIDs
        self.scheduleIDs = scheduleIDs
    }

    enum CodingKeys: String, CodingKey {
        case kind, text, time
        case personID = "person_id"
        case eventIDs = "event_ids"
        case scheduleIDs = "schedule_ids"
    }
}

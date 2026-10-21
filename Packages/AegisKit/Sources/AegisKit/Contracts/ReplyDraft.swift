import Foundation

/// Additive contract (#176): a reply Aegis suggests for someone waiting on the owner.
/// Never sent by Aegis: the owner copies it. Dates use the same IPC coding as `Answer`.
public struct ReplyDraft: Codable, Sendable, Hashable {
    public static let maxTextScalars = 600
    public var person: Brief.Person
    /// The suggested reply in the owner's style; "[...]" placeholders where only the owner knows the answer.
    public var text: String
    /// The open questions it answers, newest first by default; explicit citations keep the model's order.
    public var eventIDs: [String]
    public var model: String?
    public var generatedAt: Date

    public init(person: Brief.Person, text: String, eventIDs: [String], model: String?, generatedAt: Date) {
        self.person = person
        self.text = text
        self.eventIDs = eventIDs
        self.model = model
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case person, text, model
        case eventIDs = "event_ids"
        case generatedAt = "generated_at"
    }
}

import Foundation

/// Something the owner told Aegis to remember (#222, additive). Only the owner's own words become notes.
public struct MemoryNote: Codable, Sendable, Hashable, Identifiable {
    /// A fact to recall, a preference that shapes every reply, or a shortcut phrase.
    public enum Kind: String, Codable, Sendable {
        case fact, preference, shortcut
    }

    /// Where a note came from (#282, additive; nil in older files means `.owner`).
    public enum Origin: String, Codable, Sendable {
        /// The owner asked Aegis to remember it.
        case owner
        /// Aegis picked it up from the owner's own words in a chat (automatic memory).
        case learned
        /// Learned text the injection scanner flagged: shown to the owner, never used in a reply.
        case quarantined
        /// An observation from reflecting on the owner's notes (#315): may be wrong, replaced at each reflection.
        case reflected
    }

    public let id: String
    public var kind: Kind
    /// The owner's words; for a shortcut, what its phrase stands for.
    public var text: String
    /// A shortcut's phrase, normalised.
    public var trigger: String?
    public let createdAt: Date
    public var lastUsedAt: Date?
    public var uses: Int
    /// Nil for notes the owner asked for; see `Origin`.
    public var origin: Origin?

    /// Learned automatically rather than asked for, whether usable or quarantined.
    public var isLearned: Bool {
        origin == .learned || origin == .quarantined || origin == .reflected
    }

    public init(
        id: String, kind: Kind, text: String, trigger: String? = nil, createdAt: Date, lastUsedAt: Date? = nil,
        uses: Int = 0, origin: Origin? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.trigger = trigger
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.uses = uses
        self.origin = origin
    }
}

/// One past exchange in the panel, kept on this Mac so the owner can ask what was said before (#222).
public struct PastExchange: Codable, Sendable, Hashable {
    public let at: Date
    public let owner: String
    public let aegis: String

    public init(at: Date, owner: String, aegis: String) {
        self.at = at
        self.owner = owner
        self.aegis = aegis
    }
}

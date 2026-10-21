import Foundation

/// A rule the owner asked for in plain words, waiting for their click (never applied on its own, #179).
public struct RuleProposal: Codable, Sendable, Hashable {
    /// The local visibility setting to propose.
    public enum Action: String, Codable, Sendable {
        case mute, unmute, junk, notJunk = "not_junk"
        /// Prioritise or stop prioritising a person or group.
        case vip, unvip
        /// Add or remove a literal keyword rule.
        case keywordUrgent = "keyword_urgent", keywordHide = "keyword_hide", removeKeyword = "remove_keyword"
    }

    public var action: Action
    /// mute/unmute/vip/unvip: a `Brief.Person` ID; junk/notJunk: a trust key; keyword actions: the literal phrase.
    public var target: String
    /// The person, group or sender name shown to the owner.
    public var name: String
    /// The confirmation button's question, such as "Mute Example Family?".
    public var question: String

    public init(action: Action, target: String, name: String, question: String) {
        self.action = action
        self.target = target
        self.name = name
        self.question = question
    }
}

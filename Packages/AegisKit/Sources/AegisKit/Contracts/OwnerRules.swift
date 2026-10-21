import Foundation

/// The owner's local visibility and priority rules (#185, additive).
/// Sender sets encode as sorted arrays; absent VIP and keyword keys decode as empty.
public struct OwnerRules: Codable, Sendable, Hashable {
    /// Trust keys (`Filtered.trustKey`) of senders marked "Junk".
    public var junk: Set<String>
    /// Trust keys of senders marked "Not junk" (#167).
    public var trusted: Set<String>
    /// Muted `Brief.Person` IDs ("contact:…", "group:…", "handle:…") and the names shown when muted.
    public var muted: [String: String]

    /// VIP `Brief.Person` IDs and the names shown when prioritised. Mute and junk take precedence.
    public var vip: [String: String]
    /// Whole-word phrases typed by the owner, affecting incoming messages only.
    public var keywords: [KeywordRule]
    /// Ignored habit-based proposals (#278). Missing in older files; reads never apply or save suggestions.
    public var suggestionDismissals: [SuggestionDismissal]

    /// No owner overrides.
    public static let empty = OwnerRules()

    public init(
        junk: Set<String> = [], trusted: Set<String> = [], muted: [String: String] = [:],
        vip: [String: String] = [:], keywords: [KeywordRule] = [], suggestionDismissals: [SuggestionDismissal] = []
    ) {
        self.junk = junk
        self.trusted = trusted
        self.muted = muted
        self.vip = vip
        self.keywords = keywords
        self.suggestionDismissals = suggestionDismissals
    }

    enum CodingKeys: String, CodingKey {
        case junk, trusted, muted, vip, keywords, suggestionDismissals
    }

    /// Reads existing rules files written before VIP and keyword rules were introduced.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        junk = try container.decode(Set<String>.self, forKey: .junk)
        trusted = try container.decode(Set<String>.self, forKey: .trusted)
        muted = try container.decode([String: String].self, forKey: .muted)
        vip = try container.decodeIfPresent([String: String].self, forKey: .vip) ?? [:]
        keywords = try container.decodeIfPresent([KeywordRule].self, forKey: .keywords) ?? []
        suggestionDismissals = try container.decodeIfPresent([SuggestionDismissal].self, forKey: .suggestionDismissals) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(junk.sorted(), forKey: .junk)
        try container.encode(trusted.sorted(), forKey: .trusted)
        try container.encode(muted, forKey: .muted)
        try container.encode(vip, forKey: .vip)
        try container.encode(keywords, forKey: .keywords)
        if !suggestionDismissals.isEmpty {
            try container.encode(suggestionDismissals, forKey: .suggestionDismissals)
        }
    }
}

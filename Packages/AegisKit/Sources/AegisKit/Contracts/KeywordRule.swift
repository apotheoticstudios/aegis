import Foundation

/// An owner's literal, case-insensitive whole-word phrase rule for incoming messages (#185).
public struct KeywordRule: Codable, Sendable, Hashable {
    /// The visibility or priority effect. Collected text never creates or changes a rule.
    public enum Effect: String, Codable, Sendable, Hashable {
        case urgent, hide
    }

    /// The owner's trimmed phrase, validated to 2–60 Unicode scalars when added.
    public var phrase: String
    /// Hide matching messages or raise their checked brief items to urgent.
    public var effect: Effect

    public init(phrase: String, effect: Effect) {
        self.phrase = phrase
        self.effect = effect
    }

    /// Matches literal words in the body or title, never substrings inside another word.
    public func matches(_ event: Event) -> Bool {
        guard !SenderDisplay.isOutgoing(event), !phrase.isEmpty else { return false }
        let word = #"[\p{L}\p{M}\p{N}_]"#
        let pattern = "(?<!" + word + ")" + NSRegularExpression.escapedPattern(for: phrase) + "(?!" + word + ")"
        return [event.body, event.title ?? ""].contains {
            $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

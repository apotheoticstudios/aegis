import Foundation

/// Engaging and leaving AegisShell by the owner's own words (DESIGN.md › AegisShell, ADR-0033): "Aegis, engage",
/// "stand down". Only a whole request matches, so "engage with Sam's email" stays a question.
public enum ShellCommand: Sendable, Equatable {
    case engage, disengage
    /// "Focus mode", "switch to evening", "movie time", "back to work" (stage 6).
    case workspace(ShellWorkspace)

    public static func parse(_ text: String) -> ShellCommand? {
        let line = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^\s*(?:(?:hey|ok|okay)\s+)?[a-z]+[,!.:]\s*(?=[a-z])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey|ok|okay)\s+aegis\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:please )+|[\s?!.]+$|,?\s*please$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let shell = #"(?: (?:the )?(?:aegis ?shell|shell|aegis mode))?"#
        if line.range(of: #"^(?:aegis )?(?:engage|start|open|turn on|switch on)"# + shell + "$", options: .regularExpression) != nil,
           line.hasPrefix("engage") || line.hasPrefix("aegis engage") || line.contains("shell") || line.contains("mode")
        {
            return .engage
        }
        if let workspace = ShellWorkspace.allCases.first(where: { line.range(of: $0.spoken, options: .regularExpression) != nil }) {
            return .workspace(workspace)
        }
        if line.range(
            of: #"^(?:aegis )?(?:stand down|disengage|exit|leave|close|turn off|switch off)"# + shell + "$",
            options: .regularExpression
        )
            != nil, line.contains("stand down") || line.contains("disengage") || line.contains("shell") || line.contains("mode")
        {
            return .disengage
        }
        return nil
    }
}

/// AegisShell's four workspaces, each with its own accent, scene and art (the design system's ShellWorkspaces).
public enum ShellWorkspace: String, Sendable, CaseIterable, Codable {
    case work, focus, evening, movie

    public var name: String {
        rawValue.capitalized
    }

    /// What the owner says for it, as a regular expression over the whole request.
    var spoken: String {
        let word = switch self {
        case .work: "work"
        case .focus: "focus"
        case .evening: "evening"
        case .movie: "movie|film|cinema"
        }
        return #"^(?:(?:switch|change|go) (?:back )?to |back to |start )?(?:the )?(?:"# + word + #")(?: (?:mode|time|workspace))?$"#
    }
}

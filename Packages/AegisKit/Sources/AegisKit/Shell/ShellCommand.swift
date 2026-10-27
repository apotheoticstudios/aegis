import Foundation

/// Engaging and leaving AegisShell by the owner's own words (DESIGN.md › AegisShell, ADR-0033): "Aegis, engage",
/// "stand down". Only a whole request matches, so "engage with Sam's email" stays a question.
public enum ShellCommand: Sendable, Equatable {
    case engage, disengage

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

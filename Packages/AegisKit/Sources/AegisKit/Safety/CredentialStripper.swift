// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/security/credential_stripper.py
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis.
// swiftformat:options --maxwidth 200

import Foundation

/// Redacts credentials with OpenJarvis's patterns and replacement labels, in upstream order.
public struct CredentialStripper: Sendable {
    private static let patterns: [(label: String, regex: NSRegularExpression)] = [
        ("api_key", #"sk-[a-zA-Z0-9_-]{20,}"#),
        ("aws_key", #"AKIA[0-9A-Z]{16}"#),
        ("github_token", #"ghp_[a-zA-Z0-9]{36}"#),
        ("github_token", #"gho_[a-zA-Z0-9]{36}"#),
        ("slack_token", #"xoxb-[0-9A-Za-z\-]+"#),
        ("bearer_token", #"Bearer\s+[a-zA-Z0-9_\-.]{20,}"#),
    ].map { (label: $0.0, regex: SafetyRegex.compile($0.1)) }

    public init() {}

    /// Replaces all matching credentials without logging or retaining the input.
    public func strip(_ text: String) -> String {
        Self.patterns.reduce(text) { result, pattern in
            pattern.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED:\(pattern.label)]"
            )
        }
    }
}

public extension CredentialStripper {
    /// Wraps tool output with the upstream name/status delimiters, preserving content verbatim.
    /// This is formatting only: it neither escapes content nor strips credentials or authorizes actions.
    static func wrapToolOutput(toolName: String, content: String, success: Bool = true) -> String {
        let status = success ? "success" : "error"
        return "<tool_result name=\"\(toolName)\" status=\"\(status)\">\n\(content)\n</tool_result>"
    }
}

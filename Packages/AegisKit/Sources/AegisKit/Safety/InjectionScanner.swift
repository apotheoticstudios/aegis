// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/security/injection_scanner.py
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis.
// swiftformat:options --maxwidth 200

import Foundation

/// Findings from a prompt-injection scan, in upstream pattern order and then match order.
public struct InjectionScanResult: Sendable, Hashable {
    public let isClean: Bool
    public let findings: [ScanFinding]
    /// Highest threat found; unlike upstream's low default, clean scans have no threat level.
    public let threatLevel: ThreatLevel?

    public init(findings: [ScanFinding]) {
        isClean = findings.isEmpty
        self.findings = findings
        threatLevel = findings.map(\.threatLevel).max()
    }
}

/// Detects OpenJarvis's prompt overrides, code/shell injection, exfiltration, jailbreaks and role delimiters.
/// Detection treats scanned content only as data; it performs no actions and logs no text.
public struct InjectionScanner: Sendable {
    private struct Pattern: Sendable {
        let regex: NSRegularExpression
        let name: String
        let level: ThreatLevel
        let description: String

        init(_ pattern: String, _ name: String, _ level: ThreatLevel, _ description: String) {
            regex = SafetyRegex.compile(pattern)
            self.name = name
            self.level = level
            self.description = description
        }
    }

    private static let patterns: [Pattern] = [
        Pattern(
            #"(?i)ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompts?|rules?)"#,
            "prompt_override", .high, "Attempt to override system instructions"
        ),
        Pattern(
            #"(?i)you\s+are\s+now\s+(?:a\s+)?(?:different|new|my)"#,
            "identity_override", .high, "Attempt to change AI identity"
        ),
        Pattern(
            #"(?i)disregard\s+(?:all\s+)?(?:previous|prior|your)\s+(?:instructions?|programming|rules?)"#,
            "prompt_override", .high, "Attempt to disregard instructions"
        ),
        Pattern(
            #"(?i)(?:execute|run|eval)\s*\(\s*['\"]"#,
            "code_injection", .high, "Code execution attempt in prompt"
        ),
        Pattern(
            #"(?:;|\||&&)\s*(?:rm|curl|wget|nc|ncat|bash|sh|python|perl)\s"#,
            "shell_injection", .high, "Shell command injection"
        ),
        Pattern(
            #"(?i)(?:send|post|upload|exfiltrate|transmit)\s+(?:(?:to|data|all|everything)\s+)*(?:to\s+)?(?:https?://|my\s+server)"#, // privacy-guard: allow-network detection regex only
            "exfiltration", .high, "Data exfiltration attempt"
        ),
        Pattern(
            #"(?i)base64\s+encode\s+(?:and\s+)?(?:send|include|append)"#,
            "exfiltration", .medium, "Encoded exfiltration attempt"
        ),
        Pattern(
            #"(?i)(?:DAN|do\s+anything\s+now)\s+(?:mode|prompt|jailbreak)"#,
            "jailbreak", .high, "DAN jailbreak attempt"
        ),
        Pattern(
            #"(?i)pretend\s+(?:you\s+)?(?:have\s+)?no\s+(?:restrictions?|limitations?|rules?|filters?)"#,
            "jailbreak", .medium, "Restriction bypass attempt"
        ),
        Pattern(#"```(?:system|assistant)\b"#, "delimiter_injection", .medium, "Role delimiter injection"),
        Pattern(#"<\|(?:im_start|im_end|system|assistant)\|>"#, "delimiter_injection", .high, "Chat template injection"),
    ]

    public init() {}

    /// Finds every non-overlapping match per pattern, retaining the full range and a bounded excerpt.
    public func scan(_ text: String) -> InjectionScanResult {
        let range = NSRange(text.startIndex..., in: text)
        var findings: [ScanFinding] = []
        for pattern in Self.patterns {
            pattern.regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let matchedRange = Range(match.range, in: text) else { return }
                findings.append(ScanFinding(
                    pattern: pattern.name,
                    threatLevel: pattern.level,
                    description: pattern.description,
                    matchedText: String(text[matchedRange]),
                    start: text.unicodeScalars.distance(from: text.startIndex, to: matchedRange.lowerBound),
                    end: text.unicodeScalars.distance(from: text.startIndex, to: matchedRange.upperBound)
                ))
            }
        }
        return InjectionScanResult(findings: findings)
    }
}

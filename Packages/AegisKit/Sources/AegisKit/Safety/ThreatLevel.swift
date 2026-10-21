// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/security/types.py
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis.
// swiftformat:options --maxwidth 200

import Foundation

/// Severity classification for security findings, ordered from low to critical.
public enum ThreatLevel: String, Codable, Sendable, Hashable, Comparable {
    case low, medium, high, critical

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }

    public static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A scanner finding. Matched text is untrusted data and must never be logged or executed.
public struct ScanFinding: Codable, Sendable, Hashable {
    /// The upstream pattern name.
    public let pattern: String
    public let threatLevel: ThreatLevel
    public let description: String
    /// At most 100 Unicode scalars, matching Python's character slicing.
    public let matchedText: String
    /// Inclusive Unicode scalar offset, matching Python's character offsets rather than UTF-16 offsets.
    public let start: Int
    /// Exclusive Unicode scalar offset of the full match, before truncation.
    public let end: Int

    public init(pattern: String, threatLevel: ThreatLevel, description: String, matchedText: String, start: Int, end: Int) {
        self.pattern = pattern
        self.threatLevel = threatLevel
        self.description = description
        self.matchedText = String(matchedText.unicodeScalars.prefix(100))
        self.start = start
        self.end = end
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pattern: values.decode(String.self, forKey: .pattern),
            threatLevel: values.decode(ThreatLevel.self, forKey: .threatLevel),
            description: values.decode(String.self, forKey: .description),
            matchedText: values.decode(String.self, forKey: .matchedText),
            start: values.decode(Int.self, forKey: .start),
            end: values.decode(Int.self, forKey: .end)
        )
    }
}

/// Compiles fixed, ported patterns without silently dropping an invalid safety rule.
enum SafetyRegex {
    static func compile(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid built-in safety regular expression")
        }
    }
}

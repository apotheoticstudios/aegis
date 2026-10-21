// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/security/taint.py
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis.
// swiftformat:options --maxwidth 200

import Foundation

/// Information-flow labels carried by untrusted or sensitive data.
public enum TaintLabel: String, Codable, Sendable, Hashable {
    case pii, secret
    case userPrivate = "user_private"
    case external
}

/// Immutable labels attached to data, merged across processing steps.
public struct TaintSet: Codable, Sendable, Hashable {
    public let labels: Set<TaintLabel>

    public init(labels: Set<TaintLabel> = []) {
        self.labels = labels
    }

    /// Swift equivalent of an empty/false upstream taint set.
    public var isEmpty: Bool {
        labels.isEmpty
    }

    /// Creates a taint set from zero or more labels, removing duplicates.
    public static func fromLabels(_ labels: TaintLabel...) -> TaintSet {
        TaintSet(labels: Set(labels))
    }

    /// Returns whether the specified label is present.
    public func has(_ label: TaintLabel) -> Bool {
        labels.contains(label)
    }

    /// Merges labels without changing either input set.
    public func union(_ other: TaintSet) -> TaintSet {
        TaintSet(labels: labels.union(other.labels))
    }
}

/// OpenJarvis's taint functions (security/taint.py), kept together.
public enum TaintPolicy {
    /// OpenJarvis sink restrictions; a matching label forbids passing data to the named tool.
    /// This policy table does not grant permission to execute tools or send data.
    public static let sinkPolicy: [String: Set<TaintLabel>] = [
        "web_search": [.pii, .secret],
        "http_request": [.pii, .secret],
        "channel_send": [.secret],
        "channel_tools": [.secret],
        "code_interpreter": [.secret],
        "file_write": [.secret],
    ]

    private enum TaintPatterns {
        static let pii = [
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b"#,
            #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#,
            #"\b\+?1?\s*\(?[2-9]\d{2}\)?\s*[-.\s]?\d{3}\s*[-.\s]?\d{4}\b"#,
        ].map(SafetyRegex.compile)

        static let secret = [
            #"(?:sk|pk|api)[_-][a-zA-Z0-9]{20,}"#,
            #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,}"#,
            #"-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----"#,
            #"(?i)(?:bearer|token|password|secret|key)\s*[=:]\s*\S{8,}"#,
        ].map(SafetyRegex.compile)
    }

    /// Returns the upstream violation description, or nil for allowed labels or an unknown tool.
    /// Unknown-tool allowance is upstream behavior; callers still need Aegis action authorization.
    public static func checkTaint(toolName: String, taint: TaintSet) -> String? {
        guard let forbidden = sinkPolicy[toolName] else { return nil }
        let violations = taint.labels.intersection(forbidden)
        guard !violations.isEmpty else { return nil }
        let labels = violations.map(\.rawValue).sorted().joined(separator: ", ")
        return "Data with labels [\(labels)] cannot be sent to '\(toolName)'."
    }

    /// Removes a label with an explicit audit reason. As upstream, the reason is neither stored nor logged here.
    public static func declassify(_ taint: TaintSet, remove: TaintLabel, reason _: String) -> TaintSet {
        TaintSet(labels: taint.labels.subtracting([remove]))
    }

    /// Detects PII and secret labels using the original patterns, without retaining or logging content.
    public static func autoDetectTaint(_ text: String) -> TaintSet {
        let range = NSRange(text.startIndex..., in: text)
        var labels: Set<TaintLabel> = []
        if TaintPatterns.pii.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
            labels.insert(.pii)
        }
        if TaintPatterns.secret.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
            labels.insert(.secret)
        }
        return TaintSet(labels: labels)
    }

    /// Preserves all input labels and adds labels detected in output text.
    public static func propagateTaint(inputTaint: TaintSet, outputText: String) -> TaintSet {
        inputTaint.union(autoDetectTaint(outputText))
    }
}

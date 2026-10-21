// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/tools/approval_store.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis;
// kept as a Codable value in Aegis's private folder instead of SQLite; proposals carry Aegis actions only.
import Foundation

/// How much asking a morning-routine proposal needs (#286), as in OpenJarvis.
public enum ApprovalTier: String, Codable, Sendable, Hashable, Comparable {
    /// Runs without asking.
    case trivial
    /// Ask once per pattern, then remember.
    case low
    /// Ask each time unless the owner said "always".
    case medium
    /// Always ask; never remembered.
    case high

    /// "Always yes" and "always no" are remembered only for low and medium tiers.
    public var canRemember: Bool {
        self == .low || self == .medium
    }

    public static func < (lhs: ApprovalTier, rhs: ApprovalTier) -> Bool {
        let order: [ApprovalTier] = [.trivial, .low, .medium, .high]
        return order.firstIndex(of: lhs) ?? 0 < order.firstIndex(of: rhs) ?? 0
    }
}

/// A remembered owner decision for one permission pattern.
public enum ApprovalDecision: String, Codable, Sendable, Hashable {
    case alwaysApprove = "always_approve"
    case alwaysDeny = "always_deny"
    case ask
}

/// Where a proposal stands.
public enum ProposalStatus: String, Codable, Sendable, Hashable {
    case pending, approved, denied, expired, executed
}

/// A remembered decision, keyed by pattern ("reminder:remembered-date", "rule:mute:handle:…").
public struct PermissionRule: Codable, Sendable, Hashable {
    public var permissionKey: String
    public var decision: ApprovalDecision
    public var timesApproved: Int
    public var timesDenied: Int
    public var lastUpdated: Date

    public init(permissionKey: String, decision: ApprovalDecision, timesApproved: Int = 0, timesDenied: Int = 0, lastUpdated: Date) {
        self.permissionKey = permissionKey
        self.decision = decision
        self.timesApproved = timesApproved
        self.timesDenied = timesDenied
        self.lastUpdated = lastUpdated
    }
}

/// The owner's remembered decisions: OpenJarvis's permission memory.
public struct Approvals: Codable, Sendable, Hashable {
    public var rules: [String: PermissionRule]

    public static let empty = Approvals(rules: [:])

    public init(rules: [String: PermissionRule] = [:]) {
        self.rules = rules
    }

    /// The remembered decision for a pattern, or `.ask`.
    public func decision(for key: String) -> ApprovalDecision {
        rules[key]?.decision ?? .ask
    }

    /// Upserts a rule, counting the decision (OpenJarvis's `set_permission`).
    public mutating func set(_ key: String, decision: ApprovalDecision, approved: Bool, now: Date) {
        var rule = rules[key] ?? PermissionRule(permissionKey: key, decision: decision, lastUpdated: now)
        rule.decision = decision
        rule.timesApproved += approved ? 1 : 0
        rule.timesDenied += approved ? 0 : 1
        rule.lastUpdated = now
        rules[key] = rule
    }

    /// The learning loop (#289): counts a plain yes or no without changing the remembered decision.
    public mutating func record(_ key: String, approved: Bool, now: Date) {
        set(key, decision: decision(for: key), approved: approved, now: now)
    }

    /// A kind the owner keeps refusing: three noes, no yes, the last within 30 days. It only stops asking.
    public func learnedOff(_ key: String, now: Date) -> Bool {
        guard let rule = rules[key], rule.decision == .ask else { return false }
        return rule.timesApproved == 0 && rule.timesDenied >= 3 && now.timeIntervalSince(rule.lastUpdated) < 30 * 86400
    }

    /// How often the owner says yes to this kind, 0 to 1; 0.5 with no history.
    public func acceptance(_ key: String) -> Double {
        let yes = Double(rules[key]?.timesApproved ?? 0)
        return (yes + 1) / (yes + Double(rules[key]?.timesDenied ?? 0) + 2)
    }

    /// Forgets a remembered decision ("ask me again about …").
    public mutating func clear(_ key: String) {
        rules[key] = nil
    }
}

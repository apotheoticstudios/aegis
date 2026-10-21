import Foundation

/// Required panel approval: automatic, one click, two explicit approvals, or permanently forbidden.
public enum ActionTier: String, Codable, Sendable, CaseIterable {
    case auto, confirm, confirmTwice, never

    /// One escalation step; the never tier cannot be weakened.
    public var raised: ActionTier {
        switch self {
        case .auto: .confirm
        case .confirm: .confirmTwice
        case .confirmTwice, .never: .never
        }
    }
}

/// Stable audit codes only; never include command text, handles, paths or model explanations.
public enum ActionReasonCode: String, Codable, Sendable, CaseIterable {
    case readOnly, reversible, outwardFacing, secureAccessory
    case payment, purchase, moneyTransfer, deletion, credentials, securitySetting, privacySetting
    case unsupportedOperation, instructionLikePayload, urlPayload, ownerMinimumTier, panelClosed
}

/// Policy eligibility, not permission to execute: confirmations and executor checks still come later.
public struct ActionDecision: Codable, Sendable, Hashable {
    public let tier: ActionTier
    public let reasonCodes: [ActionReasonCode]
    public var allowed: Bool {
        tier != .never
    }

    public init(tier: ActionTier, reasonCodes: [ActionReasonCode]) {
        self.tier = tier
        self.reasonCodes = ActionReasonCode.allCases.filter { reasonCodes.contains($0) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case tier, reasonCodes, allowed
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tier = try container.decode(ActionTier.self, forKey: .tier)
        guard try container.decode(Bool.self, forKey: .allowed) == (tier != .never) else {
            throw DecodingError.dataCorruptedError(forKey: .allowed, in: container, debugDescription: "decision_mismatch")
        }
        try self.init(tier: tier, reasonCodes: container.decode([ActionReasonCode].self, forKey: .reasonCodes))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tier, forKey: .tier)
        try container.encode(reasonCodes, forKey: .reasonCodes)
        try container.encode(allowed, forKey: .allowed)
    }
}

/// Owner settings may only strengthen policy. Closed-panel requests are rejected silently.
public struct ActionOwnerSettings: Codable, Sendable, Hashable {
    public let panelIsOpen: Bool
    public let minimumTier: ActionTier

    public init(panelIsOpen: Bool = false, minimumTier: ActionTier = .auto) {
        self.panelIsOpen = panelIsOpen
        self.minimumTier = minimumTier
    }
}

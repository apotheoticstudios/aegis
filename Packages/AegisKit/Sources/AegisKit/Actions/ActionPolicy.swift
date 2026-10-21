import Foundation

/// Pure, local safety policy (#189). It neither confirms nor executes requests and has no side effects.
public enum ActionPolicy {
    /// Policy eligibility requires the open panel. Owner preferences cannot override forbidden operations.
    public static func decision(for request: ActionRequest, settings: ActionOwnerSettings = .init()) -> ActionDecision {
        let base = baseDecision(request.payload)
        var tier = base.tier
        var reasons = base.reasonCodes
        let hazards = payloadHazards(request.payload)
        if !hazards.isEmpty {
            tier = tier.raised
            reasons += hazards
        }
        if rank(settings.minimumTier) > rank(tier) {
            tier = settings.minimumTier
            reasons.append(.ownerMinimumTier)
        }
        if !settings.panelIsOpen {
            tier = .never
            reasons.append(.panelClosed)
        }
        return ActionDecision(tier: tier, reasonCodes: reasons)
    }

    private static let forbiddenVerbs: [ActionVerb: ActionReasonCode] = [
        .payment: .payment, .purchase: .purchase, .moneyTransfer: .moneyTransfer,
        .delete: .deletion, .changePassword: .credentials, .accessCredentials: .credentials,
    ]

    private static let forbiddenSettings: [ActionSystemSetting: ActionReasonCode] = [
        .security: .securitySetting, .privacy: .privacySetting, .password: .credentials, .credentials: .credentials,
    ]

    private static let supported: [ActionDomain: Set<ActionVerb>] = [
        .message: [.read, .open, .send], .home: [.read, .open, .edit],
        .app: [.read, .open, .create, .edit, .move, .send], .file: [.read, .open, .create, .edit, .move],
        .calendar: [.read, .open, .create, .edit], .reminder: [.read, .open, .create, .edit],
        .system: [.read, .edit],
    ]

    private static func baseDecision(_ payload: ActionPayload) -> ActionDecision {
        if let reason = forbiddenVerbs[payload.verb] {
            return ActionDecision(tier: .never, reasonCodes: [reason])
        }
        if case let .system(setting, _, _) = payload, let reason = forbiddenSettings[setting] {
            return ActionDecision(tier: .never, reasonCodes: [reason])
        }
        guard supported[payload.domain]?.contains(payload.verb) == true else {
            return ActionDecision(tier: .never, reasonCodes: [.unsupportedOperation])
        }
        if payload.verb == .read {
            return ActionDecision(tier: .auto, reasonCodes: [.readOnly])
        }
        if case let .home(_, characteristic, _, _) = payload {
            return homeDecision(characteristic)
        }
        if payload.verb == .send {
            return ActionDecision(tier: .confirmTwice, reasonCodes: [.outwardFacing])
        }
        return ActionDecision(tier: payload.verb == .open ? .auto : .confirm, reasonCodes: [.reversible])
    }

    private static func homeDecision(_ characteristic: ActionHomeCharacteristic) -> ActionDecision {
        // Both opening and closing secure accessories require two approvals; values never weaken this gate.
        if characteristic == .doorLock || characteristic == .garageDoor {
            return ActionDecision(tier: .confirmTwice, reasonCodes: [.secureAccessory])
        }
        return ActionDecision(tier: .confirm, reasonCodes: [.reversible])
    }

    private static func payloadHazards(_ payload: ActionPayload) -> [ActionReasonCode] {
        let fields = payload.textFields
        var reasons: [ActionReasonCode] = []
        if fields.contains(where: instructionLike) {
            reasons.append(.instructionLikePayload)
        }
        if fields.contains(where: containsURL) {
            reasons.append(.urlPayload)
        }
        return reasons
    }

    private static func instructionLike(_ text: String) -> Bool {
        // Reuse both measured input detection and BriefLayout's wider steering detection, without changing either.
        let time = Date(timeIntervalSince1970: 0)
        let event = Event(
            source: .imessage, sourceRecordID: "action-payload-check", appID: nil, sender: nil, threadID: nil,
            eventTime: time, eventTimeSource: .sent, captureTime: time, title: nil, body: text,
            content: .complete, observations: []
        )
        return BriefLayout.plantedOrder(event)
    }

    /// Portable URL recognition; Foundation's Apple-only data detectors are deliberately avoided.
    private static let urlPattern = try? NSRegularExpression(
        pattern: #"\b[a-z][a-z0-9+.-]*:(?://|[^\s])|(?<!:)//[^\s/]+|\bwww\.|"#
            + #"(?<![a-z0-9@.-])\b[a-z0-9][a-z0-9.-]*\.(?:com|org|net|edu|gov|io)(?:\b|/)"#,
        options: .caseInsensitive
    )

    private static func containsURL(_ text: String) -> Bool {
        urlPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func rank(_ tier: ActionTier) -> Int {
        switch tier {
        case .auto: 0
        case .confirm: 1
        case .confirmTwice: 2
        case .never: 3
        }
    }
}

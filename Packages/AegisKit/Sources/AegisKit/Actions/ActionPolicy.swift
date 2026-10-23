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

    private static let forbiddenShortcutWords: [(String, ActionReasonCode)] = [
        (#"\bpay(?:s|ing|ment|ments)?\b"#, .payment),
        (#"\b(?:buy|buying|purchase|order|checkout|check out)\b"#, .purchase),
        (#"\b(?:transfer|send money|wire money)\b"#, .moneyTransfer),
        (#"\b(?:delete|erase|remove|trash|wipe|purge|empty (?:the )?(?:trash|bin))\b"#, .deletion),
        (#"\b(?:passwords?|passcodes?|credentials?|keychain|log ?ins?)\b"#, .credentials),
        (#"\b(?:firewall|filevault|gatekeeper)\b"#, .securitySetting),
    ]

    /// Files that run code or install something when opened (#43): scripts, apps, installers, profiles and link files.
    private static let runsCode: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "rb", "pl", "php", "jar",
        "workflow", "action", "shortcut", "scpt", "scptd", "applescript", "pkg", "mpkg", "dmg", "mobileconfig", "configprofile",
        "prefpane", "saver", "kext", "plugin", "bundle", "systemextension", "webloc", "inetloc", "fileloc", "url", "jnlp",
    ]

    private static let supported: [ActionDomain: Set<ActionVerb>] = [
        .message: [.read, .open, .send], .home: [.read, .open, .edit],
        .app: [.read, .open, .create, .edit, .move, .send, .close], .file: [.read, .open, .create, .edit, .move],
        .calendar: [.read, .open, .create, .edit], .reminder: [.read, .open, .create, .edit],
        .system: [.read, .edit], .shortcut: [.run], .web: [.open],
    ]

    private static func baseDecision(_ payload: ActionPayload) -> ActionDecision {
        if let reason = forbiddenVerbs[payload.verb] {
            return ActionDecision(tier: .never, reasonCodes: [reason])
        }
        if case let .system(setting, _, _) = payload, let reason = forbiddenSettings[setting] {
            return ActionDecision(tier: .never, reasonCodes: [reason])
        }
        if let decision = catalogueDecision(payload) {
            return decision
        }
        guard supported[payload.domain]?.contains(payload.verb) == true else {
            return ActionDecision(tier: .never, reasonCodes: [.unsupportedOperation])
        }
        if payload.verb == .read {
            return ActionDecision(tier: .auto, reasonCodes: [.readOnly])
        }
        if case let .shortcut(name, _) = payload {
            // Aegis can't see inside a shortcut, so its name is held to the never-list (ADR-0031).
            if let reason = forbiddenShortcutWords
                .first(where: { name.range(of: $0.0, options: [.regularExpression, .caseInsensitive]) != nil })
            {
                return ActionDecision(tier: .never, reasonCodes: [reason.1])
            }
            return ActionDecision(tier: .auto, reasonCodes: [.ownerShortcut])
        }
        if case let .home(_, characteristic, _, _) = payload {
            return homeDecision(characteristic)
        }
        if payload.verb == .send {
            return ActionDecision(tier: .confirmTwice, reasonCodes: [.outwardFacing])
        }
        // Opening, and quitting an app (which asks about unsaved work itself, #49), happen at once.
        return ActionDecision(tier: [.open, .close].contains(payload.verb) ? .auto : .confirm, reasonCodes: [.reversible])
    }

    /// App automation only runs, at once (owner's choice, #43); a file that runs code never opens.
    private static func catalogueDecision(_ payload: ActionPayload) -> ActionDecision? {
        if case .automation = payload, payload.verb == .run {
            return ActionDecision(tier: .auto, reasonCodes: [.reversible])
        }
        if case .automation = payload {
            return ActionDecision(tier: .never, reasonCodes: [.unsupportedOperation])
        }
        if case let .file(path, .open) = payload, runsCode.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return ActionDecision(tier: .never, reasonCodes: [.unsupportedOperation])
        }
        return nil
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
        // A website's own address is the point of the request, not a hazard (ADR-0031).
        var address = payload.domain == .web
        if case .automation(.safariNewTab, _, _) = payload {
            address = true
        }
        if !address, fields.contains(where: containsURL) {
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

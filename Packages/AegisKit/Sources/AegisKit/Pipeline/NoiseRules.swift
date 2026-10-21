import Foundation

/// Conservative down-ranking only: questions and planted assistant orders remain candidates.
enum NoiseRules {
    private static let otp = try? NSRegularExpression(pattern: #"\botp\b"#, options: .caseInsensitive)
    private static let marketingWording = try? NSRegularExpression(
        pattern: #"\b(unsubscribe|opt out|opt-out|reply stop|text stop|stop to (opt out|unsubscribe|end)|discount|promotion)\b"#
            + #"|\bsale\s+\d+\s*%"#,
        options: .caseInsensitive
    )

    /// Verification and one-time-code notices, including the common "your code is" form.
    static func verification(_ event: Event) -> Bool {
        contains(event, ["one-time", "one time", "verification code", "verify your", "security code", "your code is"])
            || matches(event, otp)
    }

    /// Explicit opt-out wording, percentage sales, or SMS promotional sender IDs.
    static func marketing(_ event: Event) -> Bool {
        matches(event, marketingWording)
            || (event.source == .sms && ["promo", "deals", "offers"].contains { (event.sender ?? "").lowercased().contains($0) })
    }

    /// Successful routine app status and test notifications, never failure reports.
    static func appStatus(_ event: Event) -> Bool {
        event.source == .notification
            && contains(event, ["backup complete", "sync complete", "update complete", "test notification", "test alert"])
            && !contains(event, ["failed", "failure", "error"])
    }

    /// Routine delivery notices without a question; sign-in alerts remain candidates.
    static func routineNotice(_ event: Event) -> Bool {
        !event.body.contains("?") && !(event.title ?? "").contains("?")
            && contains(event, [
                "out for delivery",
                "has been delivered",
                "your package",
                "your parcel",
                "your order is",
            ])
    }

    /// No-reply style email addresses, and SMS short codes or alphanumeric sender IDs. Contacts and
    /// iMessage are always people; an unknown handle (nil) is never assumed to be a machine.
    static func automatedSender(_ event: Event) -> Bool {
        guard event.senderContact == nil else { return false }
        switch event.source {
        case .email where event.flags.contains(.bulk):
            return true
        case .email:
            let address = (event.senderHandle ?? event.sender ?? "").lowercased()
            let local = address.split(separator: "@").first.map(String.init) ?? ""
            return [
                "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
                "notification", "alerts", "mailer-daemon", "automated", "bounce",
            ].contains { local.contains($0) }
        case .sms:
            guard let handle = event.senderHandle, !handle.contains("@") else { return false }
            // Alphanumeric sender IDs: at most 11 letters, digits and . - _ (no spaces), as SMS allows.
            if handle.contains(where: \.isLetter) {
                return handle.count <= 11 && handle.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
            }
            let digits = handle.filter(\.isNumber)
            return digits.count >= 3 && digits.count <= 6 && !handle.hasPrefix("+")
        default:
            return false
        }
    }

    /// Words that keep a message out of every automated-prompt rule: failures, money and safety.
    private static let safetyWords = [
        "fail", "error", "declin", "blocked", "fraud", "unauthori", "breach", "compromis", "suspicious", "lost",
        "damaged", "emergency", "evacuat", "overdraft", "overdue", "cancel", "refund", "urgent", "was this you",
    ]

    /// Automated prompts that sound like questions (#135, from DeepSeek's categories): surveys, booking
    /// confirmations, trial and renewal reminders, delivery and order-status questions. Automated
    /// email and SMS senders only, and never with a safety word.
    static func automatedPrompt(_ event: Event) -> Bool {
        guard automatedSender(event), !contains(event, safetyWords) else { return false }
        let survey = contains(event, [
            "survey", "feedback", "rate your", "rate us", "how did we do", "how was your", "review your", "leave a review",
        ])
        let booking = contains(event, ["appointment", "reservation", "booking", "table for"])
            && contains(event, ["reply", "confirm", "reschedule"])
        let renewal = contains(event, ["free trial", "trial ends", "subscription", "membership", "renews", "renewal"])
            && contains(event, ["keep", "continue", "renew", "upgrade"])
        let delivery = contains(event, ["delivery", "parcel", "package", "courier", "redeliver", "your order", "pickup", "back in stock"])
            && (event.body.contains("?") || contains(event, ["reply", "reschedule", "still want"]))
        return survey || booking || renewal || delivery
    }

    /// Bulk or marketing email from someone who isn't a contact never reaches the model (#151).
    static func excludedBulk(_ event: Event, trusted: Set<String> = []) -> Bool {
        !isTrusted(event, trusted: trusted) && event.source == .email && event.flags.contains(.bulk) && event.senderContact == nil
    }

    /// Known message senders and safety/question exemptions bypass every noise rule.
    static func isNoise(_ event: Event, trusted: Set<String> = []) -> Bool {
        noiseReason(event, trusted: trusted) != nil
    }

    static func reason(_ event: Event, trusted: Set<String> = []) -> FilterReason? {
        if excludedBulk(event, trusted: trusted) {
            return .bulk
        }
        return noiseReason(event, trusted: trusted)
    }

    private static func isTrusted(_ event: Event, trusted: Set<String>) -> Bool {
        if let handle = event.senderHandle, trusted.contains(Filtered.trustKey(handle)) {
            return true
        }
        return event.source == .notification && event.appID.map { trusted.contains(Filtered.trustKey($0)) } == true
    }

    private static func noiseReason(_ event: Event, trusted: Set<String>) -> FilterReason? {
        guard !isTrusted(event, trusted: trusted) else { return nil }
        if event.source == .imessage || event.source == .sms, event.senderContact != nil {
            return nil
        }
        guard !BriefInputPolicy.asksOwner(event), !BriefInputPolicy.givesOrders(event) else { return nil }
        if verification(event) {
            return .code
        }
        if marketing(event) {
            return .promotion
        }
        if appStatus(event) {
            return .appNotice
        }
        if routineNotice(event) {
            return .delivery
        }
        if automatedPrompt(event) {
            return .automated
        }
        return nil
    }

    private static func matches(_ event: Event, _ pattern: NSRegularExpression?) -> Bool {
        guard let pattern else { return false }
        return [event.body, event.title ?? ""].contains {
            pattern.firstMatch(in: $0, range: NSRange($0.startIndex ..< $0.endIndex, in: $0)) != nil
        }
    }

    private static func contains(_ event: Event, _ phrases: [String]) -> Bool {
        let body = event.body.lowercased(), title = (event.title ?? "").lowercased()
        return phrases.contains { body.contains($0) || title.contains($0) }
    }
}

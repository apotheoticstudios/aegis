import Foundation

/// Deterministic tidying of a checked draft (owner's review of the test day, 2026-10-10). The model keeps
/// choosing what matters and how urgent it is; this only fixes how items read:
/// - An item that blends several people's requests, or several questions, becomes one item per message,
///   quoting the message itself, so nobody's request is blurred, misattributed or lost.
/// - An item made only of planted orders becomes a fixed sentence that never repeats them.
/// - Each item records the one person its events came from, so the panel can group them.
/// Text comes from the cited events' sender labels and bodies only; at most `maxTidiedItems` items and
/// `maxUrgent` urgent items result.
enum BriefLayout {
    /// No names, numbers or action verbs, so it can never state something its citations don't.
    static let ordersNotice = "contained instructions meant for an assistant; none were followed."

    /// Wider than the input marker (which stays as the model has been measured with): also "ignore your
    /// rules" and attempts to steer priority such as "rank this urgent" (owner's test review).
    private static let steering = try? NSRegularExpression(
        pattern: #"\b(?:ignore|disregard|forget|override)\s+(?:all\s+)?(?:of\s+)?(?:your|the|these|those)\s+"#
            + #"(?:rules|instructions|guidelines)\b|\b(?:rank|mark|flag|label|treat)\s+(?:this|it|these)\s+"#
            + #"(?:message\s+)?(?:as\s+)?urgent\b"#,
        options: .caseInsensitive
    )

    /// Collected text giving orders to an assistant: never quoted, never urgent.
    static func plantedOrder(_ event: Event) -> Bool {
        if BriefInputPolicy.givesOrders(event) {
            return true
        }
        let text = [event.title, event.body].compactMap(\.self).joined(separator: "\n")
        return steering?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func tidy(_ items: [Brief.Item], events: [String: Event], maxUrgent: Int, rules: OwnerRules = .empty) -> [Brief.Item] {
        var result: [Brief.Item] = []
        // Everyone the day shows as a sender, including apps' notification titles ("Example Bank").
        let speakers = Set(events.values.compactMap(speaker))
            .union(events.values.filter { $0.source == .notification }.compactMap(\.title))
        for (index, item) in items.enumerated() {
            let cited = item.eventIDs.compactMap { events[$0] }
            if !cited.isEmpty, cited.allSatisfy(plantedOrder) {
                let count = cited.count == 1 ? "A message" : "Some messages"
                result.append(Brief.Item(text: "\(count) \(ordersNotice)", priority: .fyi, eventIDs: item.eventIDs))
                continue
            }
            // The owner's own messages are never an item of their own, and never a second "speaker" that splits a
            // question from its answer (#212): "Do you want to go to the museum?" and "Yes" are one item.
            let incoming = cited.filter { !SenderDisplay.isOutgoing($0) }
            if !cited.isEmpty, incoming.isEmpty {
                continue
            }
            let senders = Set(incoming.compactMap(speaker))
            let questions = incoming.filter(BriefInputPolicy.asksOwner).count
            // Never quote planted orders: an item that mixes them in keeps the model's wording.
            // Only well-formed items are split: a repeated citation stays for the contract check to reject.
            let split = incoming.count > 1 && Set(item.eventIDs).count == item.eventIDs.count
                && (senders.count > 1 || questions > 1 || Set(incoming.map { EventEvidence.thread($0) ?? $0.id }).count > 1)
                && !cited.contains(where: plantedOrder)
            // Splitting may only use room the rest of the draft leaves.
            // People's items fold into one entry each in the panel, so splitting no longer lengthens the
            // brief; a hard ceiling still bounds it.
            let remaining = items.count - index - 1
            if cited.count == 1, let fixed = requoted(item, event: cited[0], speakers: speakers) {
                result.append(fixed)
                continue
            }
            guard split, result.count + incoming.count + remaining <= maxTidiedItems,
                  let quoted = Optional(incoming.map { quote($0, priority: item.priority) }),
                  !quoted.contains(where: { $0 == nil })
            else {
                result.append(item)
                continue
            }
            // Each quote keeps the owner's replies from its own conversation as sources.
            let replies = cited.filter(SenderDisplay.isOutgoing)
            result += zip(incoming, quoted.compactMap(\.self)).map { question, quote in
                var quote = quote
                quote.eventIDs += replies
                    .filter { EventEvidence.thread($0) != nil && EventEvidence.thread($0) == EventEvidence.thread(question) }.map(\.id)
                return quote
            }
        }
        return prioritised(result, events: events, maxUrgent: maxUrgent, rules: rules)
    }

    /// The final pass shares one urgent cap for calibration, VIPs and owner keywords.
    static func prioritised(
        _ items: [Brief.Item], events: [String: Event], maxUrgent: Int, rules: OwnerRules = .empty
    ) -> [Brief.Item] {
        // Splitting an urgent item never raises the urgent count above the limit: extras become replies.
        var urgent = 0
        let contacts = contactIDs(events)
        let answered = answeredQuestions(events)
        return items.map { item in
            var item = item
            let cited = item.eventIDs.compactMap { events[$0] }
            item.person = person(of: cited, contacts: contacts)
            item.priority = calibrated(item.priority, cited: cited, answered: answered)
            item.priority = ownerPriority(item.priority, cited: cited, contacts: contacts, rules: rules)
            guard item.priority == .urgent else { return item }
            urgent += 1
            if urgent > maxUrgent {
                item.priority = .reply
            }
            return item
        }
    }

    /// Multiple named people in one record are easy to swap: preserve the exact quote and its sender.
    /// Nil keeps the model's words when no other known person is named.
    static func requoted(_ item: Brief.Item, event: Event, speakers: Set<String>) -> Brief.Item? {
        guard !plantedOrder(event), let who = speaker(event) else { return nil }
        func named(_ label: String) -> Bool {
            BriefPeople.forms(of: label).contains { BriefPeople.mentions(item.text, $0) }
        }
        let others = speakers.filter {
            $0.count >= 4 && $0 != who && who.range(of: $0, options: .caseInsensitive) == nil
        }
        guard others.contains(where: named) else { return nil }
        return quote(event, priority: item.priority)
    }

    /// The same priority rules for every model (the model's own ranking drifts between models and Macs):
    /// urgent needs something time-critical or an alert in an incoming cited message; anything that asks the
    /// owner something is at least a reply. Planted orders are never raised.
    static func calibrated(_ priority: Brief.Priority, cited: [Event], answered: Set<String> = []) -> Brief.Priority {
        let incoming = cited.filter { !SenderDisplay.isOutgoing($0) }
        guard !incoming.isEmpty, !incoming.contains(where: plantedOrder) else { return priority }
        // The item itself cites the owner's reply to everything it asks (#212): answered, so at most FYI.
        let replies = cited.filter(SenderDisplay.isOutgoing)
        let questions = incoming.filter { BriefInputPolicy.asksOwner($0) || requests($0) }
        if !questions.isEmpty, questions.allSatisfy({ question in
            replies
                .contains {
                    EventEvidence.thread($0) != nil && EventEvidence.thread($0) == EventEvidence.thread(question) && $0.eventTime > question
                        .eventTime
                }
        }), !incoming.contains(where: { timeCritical($0) || alert($0) }) {
            return .fyi
        }
        // A question the owner replied to later, in a reply this item doesn't cite, may still be open (an
        // unrelated reply leaves a request open): it isn't raised, the model's judgement stands.
        let pressing = incoming.contains { timeCritical($0) || alert($0) }
        let asks = !questions.isEmpty
        if pressing, asks || incoming.contains(where: alert) {
            return .urgent
        }
        if priority == .urgent {
            return asks ? .reply : .fyi
        }
        let unanswered = questions.contains { !answered.contains($0.id) }
        return priority == .fyi && unanswered ? .reply : priority
    }

    /// Incoming questions and requests the owner replied to afterwards in the same conversation (the input's
    /// "already answered" rule): their IDs.
    static func answeredQuestions(_ events: [String: Event]) -> Set<String> {
        var lastReply: [String: Date] = [:]
        for event in events.values where SenderDisplay.isOutgoing(event) {
            guard let thread = EventEvidence.thread(event) else { continue }
            lastReply[thread] = max(lastReply[thread] ?? event.eventTime, event.eventTime)
        }
        return Set(events.values.filter { event in
            guard !SenderDisplay.isOutgoing(event), let thread = EventEvidence.thread(event),
                  let reply = lastReply[thread] else { return false }
            return reply > event.eventTime && (BriefInputPolicy.asksOwner(event) || requests(event))
        }.map(\.id))
    }

    static func timeCritical(_ event: Event) -> Bool {
        matches(event, timeCriticalPattern)
    }

    static func alert(_ event: Event) -> Bool {
        matches(event, alertPattern)
    }

    /// "Please contact…", "call me", "let me know": a request without a question mark.
    static func requests(_ event: Event) -> Bool {
        !NoiseRules.automatedSender(event) && matches(event, requestPattern)
    }

    private static func matches(_ event: Event, _ pattern: NSRegularExpression?) -> Bool {
        let text = [event.title, event.body].compactMap(\.self).joined(separator: "\n")
        return pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let timeCriticalPattern = try? NSRegularExpression(
        pattern: #"\b(?:today|tonight|asap|urgent(?:ly)?|immediately|right now|this (?:morning|afternoon|evening)|"#
            + #"by (?:\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|midday|eod|end of (?:the )?day)|"#
            + #"before (?:\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|tomorrow)|in (?:\d+|a few|an?) (?:mins?|minutes?|hours?))\b"#,
        options: [.caseInsensitive]
    )

    private static let alertPattern = try? NSRegularExpression(
        pattern: #"\b(?:failed|failure|declined|suspended|locked|overdue|expired|unusual sign-?in|security alert)\b"#,
        options: [.caseInsensitive]
    )

    private static let requestPattern = try? NSRegularExpression(
        pattern: #"\b(?:please (?:contact|call|reply|respond|confirm|send|check|let me know)|call me|let me know|get back to me)\b"#,
        options: [.caseInsensitive]
    )

    /// Upper bound after splitting (the model's own draft stays within BriefChecks.maxItems).
    static let maxTidiedItems = 20

    /// Contacts' names and handles to contacts, so a Messages notification titled with a contact's name or
    /// number joins that contact.
    static func contactIDs(_ events: [String: Event]) -> [String: Event.ContactRef] {
        var contacts: [String: Event.ContactRef] = [:]
        var ambiguous = Set<String>()
        for event in events.values {
            guard let contact = event.senderContact else { continue }
            for key in [contact.name, event.senderHandle.map(handleKey)].compactMap(\.self) {
                if let existing = contacts[key], existing.id != contact.id {
                    ambiguous.insert(key)
                }
                contacts[key] = contact
            }
        }
        return contacts.filter { !ambiguous.contains($0.key) }
    }

    /// Phone numbers compare by digits; other handles as written, ignoring case.
    static func handleKey(_ handle: String) -> String {
        let digits = handle.filter(\.isNumber)
        return digits.count >= 7 && !handle.contains("@") ? "tel:" + digits : handle.lowercased()
    }

    /// The single person (or group chat) an item's events came from: a group chat, a contact, or the handle
    /// of a message from someone who isn't one. Emails from non-contacts and app notifications are about
    /// nobody in particular.
    static func person(of events: [Event], contacts: [String: Event.ContactRef]) -> Brief.Person? {
        let people = events.map { event -> Brief.Person? in
            // A group chat's items belong to the group, apart from each member's own chats (owner's request).
            if event.source == .imessage || event.source == .sms, let thread = event.threadID, thread.contains(";+;") {
                let name = event.title?.trimmingCharacters(in: .whitespaces) ?? ""
                return Brief.Person(id: "group:" + thread, name: name.isEmpty ? "Group chat" : name)
            }
            if SenderDisplay.isOutgoing(event) {
                return nil
            }
            if let contact = event.senderContact {
                return Brief.Person(id: "contact:" + contact.id, name: contact.name)
            }
            if event.source == .notification, MessagesApp.contains(event.appID),
               let title = event.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty
            {
                if let contact = contacts[title] ?? contacts[handleKey(title)] {
                    return Brief.Person(id: "contact:" + contact.id, name: contact.name)
                }
                return Brief.Person(id: "handle:" + title, name: title)
            }
            if event.source == .imessage || event.source == .sms, let handle = event.senderHandle, !handle.isEmpty {
                return Brief.Person(id: "handle:" + handle, name: handle)
            }
            return nil
        }
        guard let first = people.first, let person = first, people.allSatisfy({ $0?.id == person.id }) else { return nil }
        return person
    }

    /// Who sent it: a Messages notification names its sender in the title; otherwise the sender label.
    static func speaker(_ event: Event) -> String? {
        if event.source == .notification, MessagesApp.contains(event.appID),
           let title = event.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty
        {
            return title
        }
        return SenderDisplay.label(event).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "Alex asked: “Can you confirm the venue?”", "Alex asked in Example group: …" or "Example Bank: “…”".
    static func quote(_ event: Event, priority: Brief.Priority) -> Brief.Item? {
        guard let sender = speaker(event) else { return nil }
        // A group chat's name, when it isn't just the sender's name (one-to-one chats).
        let chat = event.threadID?.contains(";+;") == true ? event.title?.trimmingCharacters(in: .whitespaces) : nil
        let group = chat.flatMap { $0.isEmpty || $0.caseInsensitiveCompare(sender) == .orderedSame ? nil : " in \($0)" } ?? ""
        let lead = BriefInputPolicy.asksOwner(event) ? "\(sender) asked\(group): " : "\(sender)\(group): "
        let words = event.body.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        var body = String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !body.isEmpty else { return nil }
        let room = BriefChecks.maxItemScalars - lead.unicodeScalars.count - 3
        guard room > 20 else { return nil }
        if body.unicodeScalars.count > room {
            body = String(String.UnicodeScalarView(body.unicodeScalars.prefix(room - 1))) + "…"
        }
        return Brief.Item(text: lead + "“" + body + "”", priority: priority, eventIDs: [event.id])
    }
}

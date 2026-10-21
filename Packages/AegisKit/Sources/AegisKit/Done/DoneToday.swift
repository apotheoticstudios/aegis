import Foundation

/// Today's completions from records alone (#211). Collected content never reaches a model or action system.
public enum DoneToday {
    // The additive API takes the three record sets and the caller's identity, time and result bounds.
    // swiftlint:disable function_parameter_count
    /// Computes the owner's local day from its start through `now`, newest first, with a stable tie order.
    /// The caller supplies named, merged events already filtered by `OwnerRules.visible`; include seven days
    /// of history for promises. `contacts` uses `BriefLayout.contactIDs` and its normalized handle keys.
    public static func compute(
        events: [Event], occurrences: [CalendarOccurrence], reminders: [ReminderItem],
        contacts: [String: Event.ContactRef], now: Date, calendar: Calendar, maxItems: Int
    ) -> [DoneItem] {
        guard maxItems > 0 else { return [] }
        let start = calendar.startOfDay(for: now)
        let today = events.filter { $0.eventTime >= start && $0.eventTime <= now }
        let promises = Commitments.fulfilled(events: events, contacts: contacts, now: now, calendar: calendar)
            .filter { $0.completion.eventTime >= start }.map { kept in
                DoneItem(
                    kind: .promiseKept, text: "Kept your promise to \(kept.promise.person): “\(kept.promise.text)”",
                    time: kept.completion.eventTime, personID: kept.promise.personID,
                    eventIDs: [kept.promise.eventID, kept.completion.id], scheduleIDs: []
                )
            }
        let items = answered(today, contacts: contacts) + promises
            + completed(reminders, start: start, now: now) + held(occurrences, start: start, now: now, calendar: calendar)
        return Array(items.sorted(by: ordered).prefix(maxItems))
    }

    // swiftlint:enable function_parameter_count

    private static func answered(_ events: [Event], contacts: [String: Event.ContactRef]) -> [DoneItem] {
        let outgoing = events.filter { SenderDisplay.isOutgoing($0) && $0.source != .notification }.sorted {
            ($0.eventTime, $0.id) < ($1.eventTime, $1.id)
        }
        var replies: [String: [Event]] = [:]
        for event in outgoing {
            if let key = threadKey(event) {
                replies[key, default: []].append(event)
            }
            for handle in event.recipients where !handle.isEmpty {
                replies[handleKey(handle, source: event.source), default: []].append(event)
            }
        }
        return events.compactMap { question in
            guard !SenderDisplay.isOutgoing(question),
                  BriefInputPolicy.asksOwner(question) || BriefLayout.requests(question),
                  !BriefLayout.plantedOrder(question), !NoiseRules.isNoise(question),
                  let key = threadKey(question) ?? question.senderHandle.map({ handleKey($0, source: question.source) }),
                  let reply = firstReply(replies[key] ?? [], after: question.eventTime)
            else { return nil }
            let person = BriefLayout.person(of: [question], contacts: contacts)
            let who = person?.name ?? SenderDisplay.label(question) ?? "someone"
            let target = person?.id.hasPrefix("group:") == true ? "in \(excerpt(who, limit: 120))" : excerpt(who, limit: 120)
            let text = "Answered \(target): “\(excerpt(CommitmentText.body(question), limit: 80))”"
                + " — you said “\(excerpt(CommitmentText.body(reply), limit: 60))”"
            return DoneItem(
                kind: .answered, text: text, time: reply.eventTime, personID: person?.id,
                eventIDs: [question.id, reply.id], scheduleIDs: []
            )
        }
    }

    private static func threadKey(_ event: Event) -> String? {
        guard let thread = event.threadID, !thread.isEmpty else { return nil }
        return (event.source == .email ? "email-thread:" : "messages-thread:") + thread
    }

    private static func handleKey(_ handle: String, source: Event.Source) -> String {
        (source == .email ? "email-handle:" : "messages-handle:") + BriefLayout.handleKey(handle)
    }

    private static func firstReply(_ replies: [Event], after time: Date) -> Event? {
        var lower = 0
        var upper = replies.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if replies[middle].eventTime <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < replies.count ? replies[lower] : nil
    }

    private static func completed(_ reminders: [ReminderItem], start: Date, now: Date) -> [DoneItem] {
        reminders.compactMap { reminder in
            guard reminder.isCompleted, let time = reminder.completedAt, time >= start, time <= now else { return nil }
            return DoneItem(
                kind: .reminderCompleted, text: "Completed: \(reminder.title)", time: time, personID: nil,
                eventIDs: [], scheduleIDs: [reminder.id]
            )
        }
    }

    private static func held(_ occurrences: [CalendarOccurrence], start: Date, now: Date, calendar: Calendar) -> [DoneItem] {
        occurrences.compactMap { occurrence in
            guard !occurrence.isAllDay, occurrence.status != .cancelled,
                  occurrence.end >= start, occurrence.end < now else { return nil }
            let text = "\(occurrence.title), \(clock(occurrence.start, calendar: calendar))–\(clock(occurrence.end, calendar: calendar))"
            return DoneItem(
                kind: .eventHeld, text: text, time: occurrence.end, personID: nil, eventIDs: [], scheduleIDs: [occurrence.id]
            )
        }
    }

    private static func clock(_ time: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? Unicode.Scalar(UInt8(32)) : scalar
        }
        let line = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static func ordered(_ lhs: DoneItem, _ rhs: DoneItem) -> Bool {
        if lhs.time != rhs.time {
            return lhs.time > rhs.time
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.eventIDs != rhs.eventIDs {
            return lhs.eventIDs.lexicographicallyPrecedes(rhs.eventIDs)
        }
        if lhs.scheduleIDs != rhs.scheduleIDs {
            return lhs.scheduleIDs.lexicographicallyPrecedes(rhs.scheduleIDs)
        }
        return lhs.text < rhs.text
    }
}

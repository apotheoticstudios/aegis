import Foundation

/// What Aegis treated as junk (#167): grouped by sender, for the panel's Filtered list.
public enum Filtered {
    /// The key a sender is trusted by: lower-cased handle (or bundle ID for notifications).
    public static func trustKey(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Senders whose messages were junk, most filtered first. Trusted senders and muted people never appear.
    /// Owner-marked junk takes precedence over automatic reasons (#175).
    public static func compute(events: [Event], rules: OwnerRules, maxSenders: Int) -> [FilteredSender] {
        guard maxSenders > 0 else { return [] }
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contacts = BriefLayout.contactIDs(byID)
        var groups: [String: [Record]] = [:]
        for event in events where !SenderDisplay.isOutgoing(event) {
            guard let record = record(event, rules: rules, contacts: contacts) else { continue }
            groups[trustKey(record.handle), default: []].append(record)
        }
        let rows = groups.map { key, records in
            let ordered = records.sorted {
                if $0.event.eventTime != $1.event.eventTime {
                    return $0.event.eventTime > $1.event.eventTime
                }
                return scalarLess($0.event.id, $1.event.id)
            }
            let newest = ordered[0]
            let event = newest.event
            let sender = event.source == .notification ? (event.title ?? event.appID ?? newest.handle)
                : (SenderDisplay.label(event) ?? newest.handle)
            let text = event.source == .email ? (event.title ?? "") : event.body
            let space: Unicode.Scalar = " "
            let line = String(String.UnicodeScalarView(text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? space : $0
            }))
            let latest = line.unicodeScalars.count > 120 ? scalarPrefix(line, 119) + "…" : line
            return (key: key, time: event.eventTime, row: FilteredSender(
                sender: sender, handle: newest.handle, reason: newest.reason, count: records.count,
                latest: latest, eventIDs: ordered.prefix(10).map(\.event.id)
            ))
        }
        return rows.sorted {
            if $0.row.count != $1.row.count {
                return $0.row.count > $1.row.count
            }
            if $0.time != $1.time {
                return $0.time > $1.time
            }
            return scalarLess($0.key, $1.key)
        }.prefix(maxSenders).map(\.row)
    }

    private static func record(_ event: Event, rules: OwnerRules, contacts: [String: Event.ContactRef]) -> Record? {
        if let person = BriefLayout.person(of: [event], contacts: contacts), rules.muted[person.id] != nil {
            return nil
        }
        let hidden = rules.hide(event, contacts: contacts)
        guard hidden != .keyword, !rules.isVIP(event, contacts: contacts) || hidden == .junk else { return nil }
        guard let handle = event.senderHandle ?? (event.source == .notification ? event.appID : nil) else { return nil }
        let key = trustKey(handle)
        guard !key.isEmpty, !rules.trusted.contains(key),
              let reason = rules.junk.contains(key) ? .markedJunk : NoiseRules.reason(event, trusted: rules.trusted)
        else { return nil }
        return Record(event: event, reason: reason, handle: handle)
    }
}

private struct Record {
    let event: Event
    let reason: FilterReason
    let handle: String
}

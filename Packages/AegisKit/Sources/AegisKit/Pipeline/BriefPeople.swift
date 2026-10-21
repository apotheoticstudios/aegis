import Foundation

/// Swapped speakers (morning 1 of the Stage 1 test): the model attached a contact who sent one event to
/// items about unrelated events. An item may name a contact only when that contact is connected to its
/// citations: they sent a cited event, or are named in a cited
/// event's title, body or sender. Only contacts' names are checked (full name, or first name as written),
/// so other capitalised words are never second-guessed.
enum BriefPeople {
    /// Contacts who sent events in the input: the people an item could wrongly name.
    static func contacts(in events: [String: Event]) -> Set<String> {
        Set(events.values.compactMap { $0.senderContact?.name }.filter { !$0.isEmpty })
    }

    /// True when the item names a contact unconnected to its citations.
    static func namesUnconnectedContact(_ item: Brief.Item, events: [String: Event], contacts: Set<String>) -> Bool {
        let cited = item.eventIDs.compactMap { events[$0] }
        let connected = Set(cited.compactMap { $0.senderContact?.name })
        let evidence = cited.flatMap { [$0.title ?? "", $0.body, $0.sender ?? "", $0.senderHandle ?? ""] }
            .joined(separator: "\n")
        for name in contacts where !connected.contains(name) {
            for form in forms(of: name) where mentions(item.text, form) {
                let grounded = mentions(evidence, form) || connected.contains { mentions($0, form) }
                if !grounded {
                    return true
                }
            }
        }
        return false
    }

    /// The full name (any case) and, for a name of two or more words, the first name as written.
    static func forms(of name: String) -> [(text: String, anyCase: Bool)] {
        let full = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = full.split(whereSeparator: \.isWhitespace)
        guard words.count > 1, let first = words.first, first.count >= 3 else { return [(full, true)] }
        return [(full, true), (String(first), false)]
    }

    static func mentions(_ text: String, _ form: (text: String, anyCase: Bool)) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: form.text) + #"(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: form.anyCase ? [.caseInsensitive] : []) else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

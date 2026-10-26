import Foundation

/// Source/sender constraints come from the owner's question; message bodies never establish identity.
struct AskSelection {
    enum Source { case mail, messages, communications }
    let source: Source?
    let sender: String?
    let direction: Event.Direction?
    let terms: [String]
    let overview: Bool
    var isReadRequest: Bool {
        source != nil || overview || sender != nil
    }

    init(_ question: String, query: AskQuery) {
        let words = AskQuery.words(question)
        let timed = words.contains { [
            "today",
            "yesterday",
            "tonight",
            "morning",
            "week",
            "days",
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday",
            "sunday",
        ].contains($0) }
        let read = words.contains { ["read", "translate", "summarize", "summarise", "say", "said", "says"].contains($0) }
        let specific = timed || words.contains("my") || words.contains("from") || words.contains("received")
            || words.contains("get") || words.contains("got") || read && (words.contains("the") || words.contains("that"))
        let mailWords = Set(["mail", "email", "emails", "inbox"])
        let messageWords = Set(["message", "messages", "texts", "sms", "imessage"])
        let mail = words.firstIndex(where: mailWords.contains)
        let messages = words.firstIndex(where: messageWords.contains)
        let requested: Source? = if let mail, let messages {
            words[min(mail, messages) ..< max(mail, messages)].contains("and") ? .communications : (mail < messages ? .mail : .messages)
        } else if mail != nil {
            .mail
        } else if messages != nil {
            .messages
        } else {
            nil
        }
        source = specific && !Chat.isRequestToAct(question) ? requested : nil
        let sent = question.range(
            of: #"\b(?:did i|have i|i)\s+(?:send|sent|write|wrote|email|emailed|text|texted)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        // "What have I got on" is the calendar, not what arrived.
        let received = !query.schedule && words.contains { ["get", "got", "receive", "received", "inbox"].contains($0) }
        direction = sent ? .outgoing : (received ? .incoming : nil)
        let pattern = #"\b(?:from|sent by|written by)\s+(.+?)(?=\s+(?:today|yesterday|tonight|this|last|next|on|about|regarding|say|said|says|to|in|mention|mentions|mentioned)\b|[?!]|$)"#
        let raw = source == nil ? nil : question.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map {
            String(question[$0]).replacingOccurrences(
                of: #"^(?:from|sent by|written by)\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.,")))
        }
        let timeWords = Set(["today", "yesterday", "tonight", "this", "last", "next"])
        sender = raw.flatMap { $0.count <= 100 && !timeWords.contains(AskQuery.words($0).first ?? "") ? $0 : nil }
        let sourceWords: Set<String> = switch source {
        case .mail: mailWords
        case .messages: messageWords
        case .communications: mailWords.union(messageWords)
        case nil: []
        }
        let filler = Set(("read summarize summarise translate mention mentions mentioned "
                + "received receive sent send say says happened happen missed miss new recent latest recently gotten "
                + "monday tuesday wednesday thursday friday saturday sunday").split(separator: " ").map(String.init)).union(sourceWords)
        let senderWords = Set(AskQuery.words(sender ?? ""))
        terms = query.keywords.filter { !filler.contains($0) && !senderWords.contains($0) }
        overview = terms.isEmpty && (source != nil || timed && (received || words.contains { ["happened", "missed", "new"].contains($0) }))
    }

    func matches(_ event: Event, senderIDs: Set<String> = []) -> Bool {
        if source != nil || overview {
            if direction == .incoming, SenderDisplay.isOutgoing(event) {
                return false
            }
            if direction == .outgoing, !SenderDisplay.isOutgoing(event) {
                return false
            }
        }
        switch source {
        case .mail where event.source != .email: return false
        case .messages where ![.imessage, .sms].contains(event.source): return false
        case .communications where event.source == .notification: return false
        default: break
        }
        guard let sender else { return true }
        if let id = event.senderContact?.id, senderIDs.contains(id) {
            return true
        }
        let wanted = Self.compact(sender)
        guard !wanted.isEmpty else { return false }
        let name = event.senderContact?.name ?? event.sender?.components(separatedBy: "<").first ?? ""
        if Self.compact(name) == wanted {
            return true
        }
        if let handle = event.senderHandle {
            let index = ContactIndex([])
            if index.key(for: sender) == index.key(for: handle) {
                return true
            }
            // A spoken company name may be the email domain, without spaces or the public suffix.
            if !sender.contains("@"), let domain = handle.split(separator: "@").last, handle.contains("@") {
                return domain.split(separator: ".").dropLast().contains { Self.compact(String($0)) == wanted }
            }
        }
        return false
    }

    private static func compact(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber })
    }
}

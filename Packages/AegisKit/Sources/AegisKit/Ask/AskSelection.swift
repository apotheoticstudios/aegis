import Foundation

/// Source/sender constraints come from the owner's question; message bodies never establish identity.
struct AskSelection {
    enum Source { case mail, messages, communications }
    let source: Source?
    let sender: String?
    let direction: Event.Direction?
    let terms: [String]
    let overview: Bool
    let translating: Bool
    let singleTranslation: Bool
    private let chinese: Bool
    var isReadRequest: Bool {
        source != nil || overview || sender != nil
    }

    /// A correction to the previous topic does not date or replace the new request after “also”.
    static func requestText(_ question: String) -> String {
        question.replacingOccurrences(
            of: #"^\s*(?:that|it|this)\s+(?:was|is)\s+(?:yesterday|today|last night)[.!]?\s+(?:also|anyway)[,:]?\s+(.+)$"#,
            with: "$1", options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Make the active read-only translation task explicit for a small model.
    func modelQuestion(_ question: String) -> String {
        guard translating else { return question }
        return "Translate the selected source text now, into the requested language or otherwise the owner's language. "
            + (singleTranslation ? "The most recent matching message is selected. " : "")
            + "Provide the actual translation, not an offer. Owner request: " + question
    }

    init(_ question: String, query: AskQuery) {
        let words = AskQuery.words(question)
        let translating = words.contains("translate") || words.contains("translation")
        self.translating = translating
        singleTranslation = translating && !words.contains { ["messages", "texts", "emails"].contains($0) }
        chinese = translating && question.range(
            of: #"\b(?:from|in)\s+(?:chinese|mandarin|cantonese)\b|\b(?:chinese|mandarin|cantonese)\s+(?:text|message|email)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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
        let received = words.contains { ["get", "got", "receive", "received", "inbox"].contains($0) }
        direction = sent ? .outgoing : (received ? .incoming : nil)
        let pattern = #"\b(?:from|sent by|written by)\s+(.+?)(?=\s+(?:today|yesterday|tonight|this|last|next|on|about|regarding|"#
            + #"say|said|says|to|in|from|mention|mentions|mentioned)\b|[?!]|\.(?:\s|$)|$)"#
        let timeWords = Set(["today", "yesterday", "tonight", "this", "last", "next"])
        let languages = Self.languages
        let raw = (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
            .matches(in: question, range: NSRange(question.startIndex..., in: question)).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: question) else { return nil }
                let name = String(question[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'., "))
                guard name.count <= 100, !timeWords.contains(AskQuery.words(name).first ?? ""),
                      !(translating && languages.contains(name.lowercased())) else { return nil }
                return name
            }.last
        sender = source == nil ? nil : raw
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
        let translationWords = translating ? languages.union(["text", "translation", "into", "language"]) : []
        terms = query.keywords.filter { !filler.contains($0) && !senderWords.contains($0) && !translationWords.contains($0) }
        overview = terms.isEmpty && (source != nil || timed && (received || words.contains { ["happened", "missed", "new"].contains($0) }))
    }

    func matches(_ event: Event, senderIDs: Set<String> = []) -> Bool {
        if chinese, !event.body.unicodeScalars.contains(where: {
            (0x3400 ... 0x4DBF).contains($0.value) || (0x4E00 ... 0x9FFF).contains($0.value)
                || (0xF900 ... 0xFAFF).contains($0.value) || (0x20000 ... 0x3134F).contains($0.value)
        }) {
            return false
        }
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

    /// Language names in a translation instruction describe the content, rather than its sender.
    private static let languages: Set<String> = [
        "chinese", "mandarin", "cantonese", "english", "french", "spanish", "german", "italian", "portuguese",
        "russian", "ukrainian", "arabic", "hindi", "japanese", "korean", "vietnamese", "thai", "greek", "hebrew",
        "polish", "dutch", "turkish", "indonesian", "malay", "swedish", "tamil", "bengali", "urdu", "persian",
    ]
}

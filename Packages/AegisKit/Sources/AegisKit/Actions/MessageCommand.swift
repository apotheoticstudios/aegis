import Foundation

/// The owner asking Aegis to text or email someone (#276), from their own words only. By default Aegis prepares
/// the message and the owner sends it; "… and send it" asks Aegis to send it, after two confirmations.
public struct MessageCommand: Sendable, Equatable {
    public let channel: ActionMessageChannel
    /// Ways to split the words into a name and the message, longest name first ("text Sam Lee I'm late" could
    /// be to "Sam Lee" or to "Sam"); the panel keeps the first name that matches one contact.
    public let candidates: [Candidate]
    public let subject: String?
    /// The owner asked Aegis to send it, not just prepare it.
    public let send: Bool

    public struct Candidate: Sendable, Equatable {
        public let name: String
        public let body: String
    }

    public static func parse(_ text: String) -> MessageCommand? {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"^(?:please |can you |could you |would you )+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        guard !line.isEmpty, line.count <= 600 else { return nil }
        let sendPattern = #"[,.]?\s+(?:and\s+)?(?:just\s+|go ahead and\s+)?send it(?: now| yourself| directly| for me)?[.!]?$"#
        let send = line.range(of: sendPattern, options: [.regularExpression, .caseInsensitive]) != nil
        line = line.replacingOccurrences(of: sendPattern, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[\s]+$"#, with: "", options: .regularExpression)
        let forms: [(String, ActionMessageChannel)] = [
            (#"^(?:send (?:an? )?(?:email|e-mail|mail) to|email|e-mail) (.+)$"#, .email),
            (#"^send (.+?) an? (?:email|e-mail)(?: (?:saying|that|to say))?[,:]? (.+)$"#, .email),
            (#"^send (.+?) an? (?:text|message|imessage|sms)(?: (?:saying|that|to say))?[,:]? (.+)$"#, .message),
            (#"^(?:send (?:an? )?(?:text|message|imessage|sms) to|text|message|imessage|sms|tell) (.+)$"#, .message),
        ]
        for (pattern, channel) in forms {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            else { continue }
            let groups = (1 ..< match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
            let rest = groups.count == 2 ? groups[0] + " saying " + groups[1] : groups.first ?? ""
            // "Tell me a joke", "message me later": not a message to someone.
            guard rest
                .range(of: #"^(?:me|us|him|her|them|it|that|everyone|anyone)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
            else {
                return nil
            }
            let (subject, remainder) = channel == .email ? Self.subject(rest) : (nil, rest)
            let candidates = Self.splits(remainder)
            guard !candidates.isEmpty else { return nil }
            return MessageCommand(channel: channel, candidates: candidates, subject: subject, send: send)
        }
        return nil
    }

    /// "Sam about Friday saying the venue changed" → ("Friday", "Sam saying the venue changed").
    private static func subject(_ text: String) -> (String?, String) {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(.+?) about (.+?)(?:,|:| saying| that| to say) (.+)$"#,
            options: [.caseInsensitive]
        ),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let name = Range(match.range(at: 1), in: text), let topic = Range(match.range(at: 2), in: text),
            let body = Range(match.range(at: 3), in: text)
        else { return (nil, text) }
        let subject = String(text[topic])
        return (String(subject.prefix(1)).uppercased() + subject.dropFirst(), text[name] + " saying " + text[body])
    }

    /// Name and message: split at "saying"/"that"/a colon when given, otherwise after one to three words.
    private static func splits(_ text: String) -> [Candidate] {
        let cleaned = { (body: String) in
            body.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:")))
                .replacingOccurrences(of: #"^["“]|["”]$"#, with: "", options: .regularExpression)
        }
        if let regex = try? NSRegularExpression(
            pattern: #"^(.+?)(?:,|:| saying| that| to say| to tell (?:him|her|them)) (.+)$"#,
            options: [.caseInsensitive]
        ),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let name = Range(match.range(at: 1), in: text), let body = Range(match.range(at: 2), in: text),
            text[name].split(separator: " ").count <= 4
        {
            let message = cleaned(String(text[body]))
            return message.isEmpty ? [] : [Candidate(name: String(text[name]), body: Self.sentence(message))]
        }
        let words = text.split(separator: " ").map(String.init)
        return (1 ... min(3, max(words.count - 1, 0))).reversed().compactMap { count in
            let name = words.prefix(count).joined(separator: " ")
            let body = cleaned(words.dropFirst(count).joined(separator: " "))
            guard !body.isEmpty, name.lowercased() != "me", name.lowercased() != "us" else { return nil }
            return Candidate(name: name, body: Self.sentence(body))
        }
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// "Text Example Sam: “I'm running late”?" for the card.
    public static func summary(channel: ActionMessageChannel, to name: String, text: String, subject: String?, send: Bool) -> String {
        let what = channel == .email ? "Email " + name + (subject.map { " about “\($0)”" } ?? "") : "Text " + name
        return send ? "Send this now? " + what + ": “" + text + "”" : what + ": “" + text + "”"
    }
}

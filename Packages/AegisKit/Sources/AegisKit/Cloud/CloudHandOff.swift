import Foundation

/// Handing a question to Claude or ChatGPT (#223, ADR-0017). Only the owner's own words go, for a question with
/// nothing personal in it, with earlier turns of the same hand-off that pass the same check: never the brief,
/// messages, mail, calendar, contacts, notes or memory. AegisCore decides here and never connects to the
/// internet; the panel makes the call with the owner's own key. Off until the owner adds one.
public enum CloudHandOff {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case claude, chatgpt

        public var name: String {
            self == .claude ? "Claude" : "ChatGPT"
        }
    }

    /// What the panel can hand off to: the providers with a key, and whether complex questions go unasked.
    public struct Availability: Codable, Sendable, Hashable {
        public var providers: [Provider]
        public var automatic: Bool

        public static let none = Availability(providers: [], automatic: false)

        public init(providers: [Provider], automatic: Bool) {
            self.providers = providers
            self.automatic = automatic
        }
    }

    /// An earlier exchange of the same hand-off.
    public struct Turn: Codable, Sendable, Hashable {
        public var owner: String
        public var reply: String

        public init(owner: String, reply: String) {
            self.owner = owner
            self.reply = reply
        }
    }

    /// An answer in the conversation, or a task that makes files in its own folder (#235).
    public enum Work: String, Codable, Sendable {
        case answer, task
    }

    /// Exactly what may leave the Mac: the provider, the owner's question and earlier non-personal turns.
    public struct Request: Codable, Sendable, Hashable {
        public var provider: Provider
        public var question: String
        public var history: [Turn]
        public var work: Work

        public init(provider: Provider, question: String, history: [Turn], work: Work = .answer) {
            self.provider = provider
            self.question = question
            self.history = history
            self.work = work
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Answer on the Mac as usual.
        case local
        /// The owner named a provider but the question is personal: answer `question` on the Mac, saying `note` first.
        case keep(question: String, note: String)
        case cloud(Request)
        /// The owner named a provider that isn't set up: say this instead.
        case unavailable(String)
    }

    /// The instructions sent with every hand-off: nothing about the owner.
    public static let instructions = """
    You're answering for Aegis, a private voice assistant on the owner's Mac; it handed you this question because \
    it needs more depth than Aegis's small local model. Answer the owner directly and helpfully. Start with the \
    answer in one or two plain sentences, which are read aloud, then add detail only where it helps. Plain text in \
    short paragraphs; a fenced code block only for code. You can't see the owner's messages, calendar or files, so \
    don't ask for them.
    """

    /// The longest reply shown, in Unicode scalars.
    public static let maxShownScalars = 8000

    /// Where the owner's words go: a named provider ("ask Claude…") or a follow-up to the last hand-off.
    /// `names` are the owner's contacts, which never leave the Mac.
    public static func decide(
        _ text: String, history: [Chat.Turn], available: Availability, names: Set<String>
    ) -> Decision {
        if let (provider, question) = named(text) {
            guard available.providers.contains(provider) else {
                return .unavailable(
                    "I can't reach \(provider.name) yet: add your \(provider.name) API key under Claude and ChatGPT in "
                        + "Aegis's menu."
                )
            }
            guard !isPersonal(question, names: names) else {
                return .keep(question: question, note: "That has personal details in it, so I've kept it on your Mac.")
            }
            return .cloud(Request(
                provider: provider, question: question, history: carried(history, question: question, names: names, provider: provider),
                work: isTask(question) ? .task : .answer
            ))
        }
        // A follow-up ("make it shorter") stays with the provider that answered last.
        guard let last = history.last?.via, available.providers.contains(last), isGeneral(text, names: names) else {
            return .local
        }
        return .cloud(Request(provider: last, question: text, history: carried(history, question: text, names: names, provider: last)))
    }

    /// With automatic hand-off on: a complex general question the owner's data didn't cover goes to the first
    /// provider with a key.
    public static func automatic(_ text: String, available: Availability, names: Set<String>) -> Request? {
        guard available.automatic, let provider = available.providers.first, isComplex(text),
              isGeneral(text, names: names)
        else { return nil }
        return Request(provider: provider, question: text, history: [])
    }

    private static func isGeneral(_ text: String, names: Set<String>) -> Bool {
        !Chat.isSmallTalk(text) && !Chat.isRequestToAct(text) && MemoryCommand.parse(text) == nil
            && !isPersonal(text, names: names)
    }

    /// "Ask Claude why the sky is blue" → (.claude, "why the sky is blue").
    public static func named(_ text: String) -> (Provider, String)? {
        let pattern = #"^\s*(?:(?:hey |ok |okay )?aegis[,!.:]?\s+)?(?:please\s+|can you\s+|could you\s+)?"#
            + #"(?:ask|use|check with|get|have)\s+(claude|chat\s?gpt|gpt|open\s?ai)\b(?:\s+(?:to|about|for|if|whether))?"#
            + #"[,:]?\s+(.+)$"#
        let alone = #"^\s*(claude|chat\s?gpt)[,:]\s+(.+)$"#
        for candidate in [pattern, alone] {
            guard let regex = try? NSRegularExpression(pattern: candidate, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let who = Range(match.range(at: 1), in: text), let what = Range(match.range(at: 2), in: text)
            else { continue }
            let question = String(text[what]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            return (text[who].lowercased().hasPrefix("claude") ? .claude : .chatgpt, question)
        }
        return nil
    }

    /// Anything about the owner's own life or data: their messages, mail, calendar, people, accounts, health or
    /// home; a contact's name; an email address, phone number, street address or long number. When in doubt, it's
    /// personal and stays on the Mac.
    public static func isPersonal(_ text: String, names: Set<String>) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for pattern in personalPatterns where lower.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        // The owner's name need not be in Contacts. Preserve case to distinguish names from ordinary words.
        if text.replacingOccurrences(of: "’", with: "'").range(
            of: #"\b(?:[Ii]'m|[Ii] am)\s+\p{Lu}[\p{L}'-]+\s+\p{Lu}[\p{L}'-]+\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // A phone or account number: nine digits or more in one run ("1990-2000" is a span of years).
        let runs = lower.split { !$0.isNumber && !" ()+.-".contains($0) }
        if runs.contains(where: { $0.filter(\.isNumber).count >= 9 }) {
            return true
        }
        let words = Set(MemoryText.normalise(text).split(separator: " ").map {
            $0.hasSuffix("'s") ? String($0.dropLast(2)) : String($0)
        })
        let lowerText = " " + MemoryText.normalise(text) + " "
        for name in names {
            let full = MemoryText.normalise(name)
            if full.contains(" "), lowerText.contains(" " + full + " ") {
                return true
            }
            // Typed and dictated names may be lowercase or possessive.
            for part in full.split(separator: " ") where part.count >= 2 && words.contains(String(part)) {
                return true
            }
        }
        return false
    }

    /// A request to make something that belongs in files: a spreadsheet, a document, a report, code. Only when
    /// the owner names a provider; automatic hand-offs are always answers.
    public static func isTask(_ text: String) -> Bool {
        text.lowercased().range(of: taskPattern, options: .regularExpression) != nil
    }

    /// The whole prompt for a plan app (Codex, Claude Code): instructions, earlier turns and the owner's words.
    public static func planPrompt(_ request: Request) -> String {
        var lines = [request.work == .task ? taskInstructions : instructions + " " + answerOnly, ""]
        if !request.history.isEmpty {
            lines.append("Earlier in this conversation:")
            for turn in request.history {
                lines.append("Owner: " + turn.owner)
                lines.append("You: " + turn.reply)
            }
            lines.append("")
        }
        lines.append("Owner: " + request.question)
        return lines.joined(separator: "\n")
    }

    /// For a plan app answering a question: it must just answer.
    static let answerOnly = "Answer in this one reply from what you know: don't run commands, read files or look anything up."

    /// For a plan app doing a task in its own folder.
    public static let taskInstructions = """
    You're doing a task for the owner of this Mac, handed to you by Aegis, their private assistant. Work only in \
    the current folder: make everything there (documents as Markdown or Word files, tables as CSV or Excel files, \
    code as source files) and don't read, open or change anything outside it. Don't ask questions: make sensible \
    assumptions and note them in what you make. You can't see the owner's messages, calendar or files, so don't \
    look for them. When you finish, reply with two or three plain sentences saying what you made and the file \
    names; they're read aloud.
    """

    /// A task's folder name: the date and the first words of the request ("2026-10-12 laptop comparison").
    public static func folderName(for question: String, now: Date, calendar: Calendar) -> String {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HHmm"
        let skip: Set = [
            "a", "an", "the", "to", "for", "me", "my", "please", "make", "create", "build", "write", "draft", "of",
            "generate", "put", "together", "prepare", "design", "and", "with", "on", "about", "can", "you", "that",
        ]
        var name = ""
        for word in question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            where !skip.contains(word)
        {
            guard name.count + word.count < 40, name.split(separator: " ").count < 5 else { break }
            name += (name.isEmpty ? "" : " ") + word
        }
        return day.string(from: now) + (name.isEmpty ? " task" : " " + name)
    }

    /// Questions that need more than a quick chat: explaining, writing, planning, comparing, code, maths, or long.
    public static func isComplex(_ text: String) -> Bool {
        let words = text.split { $0 == " " || $0.isNewline }.count
        if words >= 30 {
            return true
        }
        return text.lowercased().range(of: complexPattern, options: .regularExpression) != nil
    }

    /// The opening of a reply, read aloud: the first two sentences without code or markdown.
    public static func spoken(_ reply: String) -> String {
        var text = reply.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let sentences = text.split(separator: ".", omittingEmptySubsequences: true)
        guard sentences.count > 2 || text.unicodeScalars.count > 320 else { return text }
        var opening = sentences.prefix(2).joined(separator: ".") + "."
        if opening.unicodeScalars.count > 320 {
            opening = String(String.UnicodeScalarView(opening.unicodeScalars.prefix(300))) + "…"
        }
        return opening + " The rest is in the panel."
    }

    /// The reply as shown: trimmed, at most `maxShownScalars`.
    public static func shown(_ reply: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.count > maxShownScalars else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxShownScalars))) + "…"
    }

    /// Earlier turns of the same hand-off, oldest first: at most two, while each one and everything sent together
    /// stay clear of personal details. Replies are checked as if the owner had said them ("your landlord" reads as
    /// "my landlord"), since a provider's reply can repeat or draw out a detail.
    static func carried(_ history: [Chat.Turn], question: String, names: Set<String>, provider: Provider) -> [Turn] {
        var turns: [Turn] = []
        for turn in history.reversed().prefix(2) {
            let reply = String(String.UnicodeScalarView(turn.aegis.unicodeScalars.prefix(1500)))
            guard turn.via == provider, !isPersonal(turn.owner, names: names), !isPersonal(asOwner(reply), names: names) else {
                break
            }
            let together = (turns.flatMap { [$0.owner, asOwner($0.reply)] } + [turn.owner, asOwner(reply), question])
                .joined(separator: " ")
            guard !isPersonal(together, names: names) else { break }
            turns.insert(Turn(owner: turn.owner, reply: reply), at: 0)
        }
        return turns
    }

    /// A reply as if the owner said it, so the first-person rules apply: "your" → "my", "you're" → "I'm".
    static func asOwner(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "’", with: "'")
        for (pattern, swap) in [
            (#"\byour\b"#, "my"), (#"\byours\b"#, "mine"), (#"\byou're\b"#, "I'm"), (#"\byou are\b"#, "I am"),
            (#"\byou've\b"#, "I've"), (#"\byou have\b"#, "I have"), (#"\byou\b"#, "I"),
        ] {
            line = line.replacingOccurrences(of: pattern, with: swap, options: [.regularExpression, .caseInsensitive])
        }
        return line
    }

    private static let personalPatterns = [
        // Explicit autobiographical statements, even without a possessive personal noun.
        #"\b(?:i|we)\s+(?:live|work|study)\s+(?:in|at|for|with)\b"#,
        #"\b(?:i'm|i am|we're|we are)\s+(?:currently\s+)?(?:at|staying in|staying at)\b"#,
        #"\b(?:my name is|i was born|i'm named|i am named)\b"#,
        #"\b(?:i'm|i am)\s+\d{1,3}\s+(?:years? old|year[- ]old)\b"#,
        #"\bi\s+(?:take|am taking|weigh|tested positive|tested negative)\b"#,
        #"\b(?:my|our)\s+(?:\w+\s+){0,2}(?:income|savings|weight|birthday|birthdate|date of birth|medical history|employer|clients?|customers?)\b"#,
        // Unquoted credential assignments and local file paths.
        #"\b(?:password|passcode|passphrase|api key|access token|secret key)\s*(?:is|was|=|:)\s*\S+"#,
        #"\bis\s+\S+\s+a\s+(?:good|strong|secure|safe)\s+(?:password|passcode|passphrase|pin)\b"#,
        #"(?:~/|/users/|/volumes/)\S+"#,
        // The owner's things and people.
        #"\b(?:my|our|mine)\s+(?:\w+\s+){0,2}(?:messages?|texts?|emails?|e-mails?|mail|inbox|calendar|schedule|diary|"#
            + #"meetings?|appointments?|reminders?|brief|notifications?|contacts?|photos?|pictures?|files?|documents?|"#
            + #"notes?|passwords?|pin|bank|accounts?|cards?|salary|pay|bills?|address|home|house|flat|apartment|"#
            + #"phone|number|location|health|doctor|gp|dentist|medical|medication|diagnosis|results?|symptoms?|"#
            + #"family|mum|mom|mother|dad|father|parents?|brother|sister|siblings?|wife|husband|partner|girlfriend|"#
            + #"boyfriend|son|daughter|kids?|children|baby|friends?|mates?|boss|manager|colleagues?|coworkers?|"#
            + #"teachers?|school|uni|university|job|workplace|team|landlord|neighbou?rs?|car|rego|licence|"#
            + #"passport|tax|super|insurance|loan|mortgage|debt|day|week|weekend|plans?|trip)\b"#,
        // Questions about what's happened to the owner.
        #"\bwho\b.{0,40}\b(?:texted|messaged|emailed|called|rang|sent|asked|said|wants?|is waiting|replied)\b"#,
        #"\b(?:did|has|have)\s+(?:anyone|anybody|someone|somebody)\b"#,
        #"\b(?:what's|what is|what do i have|do i have|am i)\b.{0,30}\b(?:today|tomorrow|tonight|this week|on|up to|free|busy)\b"#,
        #"\b(?:remind me|i told|i said|i promised|i owe|owes me|waiting on me|i need to reply)\b"#,
        // The owner's health, money and appointments, said in the first person.
        #"\b(?:i'm|i am|i have|i've|i feel|i've been|i was)\b.{0,40}\b(?:sick|ill|pain|hurts?|lump|rash|pregnant|"#
            + #"depressed|depression|anxious|anxiety|panic|suicidal|bleeding|fever|infection|diagnosed|cancer|"#
            + #"diabetes|asthma|adhd|bipolar|hiv|addicted|in debt|broke)\b"#,
        #"\bi\b.{0,20}\b(?:earn|owe|borrowed|got paid|get paid)\b"#,
        #"\b(?:meeting|appointment|interview|dinner|lunch|party|date|booking|flight)\b.{0,30}\b(?:today|tomorrow|tonight|"#
            + #"next week|on (?:mon|tues|wednes|thurs|fri|satur|sun)day|at \d)"#,
        // Secrets and account details.
        #"\b(?:password|passcode|passphrase|pin)\b.{0,30}(?:["'“‘].+["'”’]|\d{4,})"#,
        #"(?:["'“‘][^"'“”‘’]+["'”’]|\d{4,}).{0,30}\b(?:password|passcode|passphrase|pin)\b"#,
        #"\b(?:bsb|account|acct|card|iban|swift|tfn|medicare|licence|license|passport)\b.{0,15}\d{3,}"#,
        // The owner's people, places and things without "my" (DeepSeek's review, #235).
        #"\b(?:the|this|that)\s+(?:landlord|landlady|real estate agent|property manager|neighbou?rs?|doctor|gp|dentist|"#
            + #"specialist|surgeon|psychologist|diagnosis|medication|medicine|prescription|scan|biopsy|bank|school|"#
            + #"teacher|principal|babysitter|nanny|lease|rent|bond|boss|manager|lawyer|solicitor|accountant)\b"#,
        #"\b(?:test|blood|scan|biopsy|lab|mri|x-ray|ultrasound) results?\b"#,
        #"\b(?:the|this|that)\s+(?:email|message|text|thread|letter|voicemail|invoice|bill|statement|quote)\b"#,
        #"\b(?:lump|rash|pain|bleeding|swelling|mole|bruise|fever|infection|discharge|cough)\b.{0,25}\b(?:my|on me|i've|i have)\b"#,
        #"\b(?:i|we)\b.{0,25}\b(?:in debt|debts?|broke|bills|savings|overdrawn)\b"#,
        #"\b\d{1,2}[- ]?(?:year|month)[- ]old\b"#,
        #"\b(?:party|dinner|lunch|date|meeting|appointment|wedding|funeral)\b.{0,30}\b(?:\d{1,2}[/-]\d{1,2}|"#
            + #"\d{1,2}(?:st|nd|rd|th)|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2})\b"#,
        #"\b(?:parking|speeding|traffic|toll)\s+(?:fine|ticket|infringement)|\bappeal\b.{0,20}\b(?:fine|ticket)\b"#,
        #"\b(?:email|message|letter|note|reply|complaint)\b.{0,30}\b(?:refund|invoice|order|booking|warranty|claim)\b"#,
        #"\b(?:job|employer|resign|resignation|cover letter|interview|offer)\b.{0,40}\b[a-z0-9-]+\.(?:com|net|org|edu|gov|au|co)\b"#,
        // Details that identify someone.
        #"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#,
        #"\b\d{1,5}\s+\w+(?:\s\w+)?\s+(?:st|street|rd|road|ave|avenue|dr|drive|cres|crescent|ct|court|pl|place|"#
            + #"ln|lane|tce|terrace|way|blvd|parade|pde|hwy|highway)\b"#,
    ]

    private static let taskPattern = #"\b(?:make|create|build|write|draft|generate|put together|prepare|design|code|"#
        + #"program|research)\b.{0,80}\b(?:spreadsheets?|csv|excel|tables?|documents?|docs?|word files?|reports?|"#
        + #"presentations?|slides|decks?|websites?|web ?pages?|apps?|scripts?|programs?|code|files?|folders?|pdfs?|"#
        + #"resumes?|cvs?|cover letters?|essays?|plans?|itinerar(?:y|ies)|comparisons?|checklists?)\b|"#
        + #"\b(?:save it|save them|as a file|in a file|into a file)\b"#

    private static let complexPattern = #"\b(?:explain|describe|write|draft|compose|summari[sz]e|translate|compare|"#
        + #"contrast|analy[sz]e|calculate|solve|prove|derive|debug|code|program|script|function|algorithm|"#
        + #"implement|design|plan|outline|brainstorm|research|teach me|walk me through|step by step|in detail|"#
        + #"pros and cons|essay|story|poem|speech|cover letter|resume|cv|recipe|itinerary|workout|lesson|"#
        + #"how does|how do|why does|why do|what causes|what's the difference|what is the difference)\b"#
}

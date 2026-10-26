import Foundation

/// What to look up for the owner's question, read by the local model instead of fixed phrases (ADR-0032): whether
/// the answer is in the owner's records at all, where, when, who and what about. The model sees only the owner's own
/// words and today's date, never a record; every field is checked before it shapes a search, and an
/// unusable reply leaves the phrase rules (AskQuery, AskSelection) to decide, as before.
public struct SearchPlan: Sendable, Hashable {
    public enum Place: String, CaseIterable, Sendable {
        /// Calendar events and reminders.
        case calendar
        /// iMessage and SMS.
        case messages
        /// Email.
        case mail
    }

    /// False for general knowledge, advice and small talk: nothing of the owner's is searched.
    public let lookup: Bool
    public let places: Set<Place>
    /// The owner's time in a standard phrase ("next week", "thursday", "the next 7 days"); nil when they name none.
    /// The model normalises the wording; the dates themselves are worked out by code, exactly.
    public let when: String?
    /// Names the owner wrote, each found in the question.
    public let people: [String]
    /// What the answer is about, in the owner's words or close to them.
    public let topics: [String]
    public let direction: Event.Direction?

    public init(
        lookup: Bool, places: Set<Place>, when: String?, people: [String] = [], topics: [String] = [],
        direction: Event.Direction? = nil
    ) {
        self.lookup = lookup
        self.places = places
        self.when = when
        self.people = people
        self.topics = topics
        self.direction = direction
    }

    static let maxPeople = 3
    static let maxTopics = 6

    /// The standard time phrases the model may answer with: the ones AskQuery works out exactly.
    static let whenPattern = #"^(?:today|tonight|this morning|tomorrow|yesterday|(?:this|next|last) week|(?:this|next) weekend|"#
        + #"the (?:next|last) \d{1,3} days|(?:next |last )?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))$"#

    public static func systemPrompt() -> String {
        """
        Decide what to look up in the owner's own records to answer their question. Reply with ONLY JSON, leaving \
        out any field that would be empty, null or "any":
        {"lookup":true,"look_in":["calendar"],"when":"next week","people":["Sam"],"topics":["dentist"],"direction":"sent"}
        - lookup: true when the answer is in the owner's calendar, reminders, messages or email: their plans, events \
        and people they know (a friend's party, a flight), what they missed, what's new or urgent for them, who's \
        waiting on them, and news about something they're waiting on (an order, an application). false for general \
        knowledge, advice, recipes, maths, jokes, chit-chat and anything about the wider world.
        - look_in: every place the answer could be. calendar: events and reminders, plans, appointments, what's on, \
        being free or busy, flights, deadlines. messages: iMessage and SMS. mail: email.
        - when: the time the owner means, as exactly one of: today, tonight, this morning, tomorrow, yesterday, \
        this week, next week, last week, this weekend, next weekend, the next N days, the last N days (N a number), \
        monday to sunday (the coming one), next monday to next sunday, last monday to last sunday. Keep a weekday as \
        its name: "Saturday night" is "saturday", "Thursday arvo" is "thursday". Mind the word "the": "next week" \
        is the calendar week after this one, but "THE next week", "the coming week" and "the week ahead" are \
        "the next 7 days". "A few days" is 3 days; a fortnight is 14.
        - people: names or relations the owner wrote (Sam, Mum, the plumber).
        - topics: the main things the answer is about, as nouns from the question: dentist, invoice, parcel. \
        Never times, or the words message, email, calendar, reply or plans.
        - direction: received for what came to the owner, sent for what the owner sent.
        Examples:
        What have I got on for the next week? → {"lookup":true,"look_in":["calendar"],"when":"the next 7 days"}
        Any meetings next week? → {"lookup":true,"look_in":["calendar"],"when":"next week"}
        Am I busy over the week ahead? → {"lookup":true,"look_in":["calendar"],"when":"the next 7 days"}
        When is Alex's farewell? → {"lookup":true,"look_in":["calendar","messages","mail"],"people":["Alex"],"topics":["farewell"]}
        Am I free Saturday night? → {"lookup":true,"look_in":["calendar"],"when":"saturday"}
        Did the plumber get back to me? → {"lookup":true,"look_in":["messages","mail"],"people":["the plumber"],"direction":"received"}
        When's my dentist appointment? → {"lookup":true,"look_in":["calendar"],"topics":["dentist"]}
        What did I text Sam last night? → {"lookup":true,"look_in":["messages"],"when":"yesterday","people":["Sam"],"direction":"sent"}
        What did I miss today? → {"lookup":true,"look_in":["messages","mail"],"when":"today","direction":"received"}
        How do I make pancakes? → {"lookup":false}
        """
    }

    /// The owner's question after today's day and date, for words like "this week".
    public static func input(question: String, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        return "TODAY: " + formatter.string(from: now) + "\nOWNER ASKS: " + question
    }

    /// The checked plan, or nil when the reply isn't one. The time must be one of the standard phrases; people must
    /// appear in the owner's question (the model never adds a name); unknown places are dropped.
    public static func parse(_ reply: String, question: String) -> SearchPlan? {
        guard let object = Briefing.extractJSON(reply), let lookup = object["lookup"] as? Bool else { return nil }
        guard lookup else { return SearchPlan(lookup: false, places: [], when: nil) }
        let named = (object["look_in"] as? [String] ?? []).compactMap { Place(rawValue: $0.lowercased()) }
        let when = (object["when"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let asked = fold(question)
        let people = Array(phrases(object["people"], limit: 60).filter { asked.contains(fold($0)) }.prefix(maxPeople))
        let placeWords = Set(Place.allCases.map(\.rawValue) + ["message", "email", "emails", "calendar", "plans", "reminders", "reply"])
        let topics = Array(phrases(object["topics"], limit: 40)
            .filter { !placeWords.contains($0.lowercased()) && !people.contains($0) }.prefix(maxTopics))
        let direction: Event.Direction? = switch (object["direction"] as? String)?.lowercased() {
        case "received": .incoming
        case "sent": .outgoing
        default: nil
        }
        return SearchPlan(
            lookup: true, places: named.isEmpty ? Set(Place.allCases) : Set(named),
            when: when.flatMap { $0.range(of: whenPattern, options: .regularExpression) == nil ? nil : $0 }, people: people,
            topics: topics, direction: direction
        )
    }

    /// The plan's time as a span, worked out by AskQuery's date rules from the standard phrase. "Next week" and "the
    /// next 7 days" are used loosely for each other, by people and the model alike, so both cover from now to the end
    /// of next week: a few days too many rather than missing what the owner meant.
    /// Likewise "last week" and "the last 7 days" both run from the start of last week to now. And messages exist only
    /// in the past, so with no calendar to search, a bare weekday is the one just gone.
    public func window(now: Date, calendar: Calendar) -> DateInterval? {
        if when == "next week" || when == "the next 7 days",
           let next = AskQuery("when next week", now: now, calendar: calendar).named, next.end > now
        {
            return DateInterval(start: min(now, next.start), end: next.end)
        }
        if when == "last week" || when == "the last 7 days",
           let last = AskQuery("when last week", now: now, calendar: calendar).named, last.start < now
        {
            return DateInterval(start: last.start, end: max(now, last.end))
        }
        guard let when else { return nil }
        let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let phrase = weekdays.contains(when) && !places.contains(.calendar) ? "last " + when : when
        return AskQuery("when " + phrase, now: now, calendar: calendar).named
    }

    /// Short single-line strings from a JSON list.
    private static func phrases(_ value: Any?, limit: Int) -> [String] {
        (value as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= limit && $0.rangeOfCharacter(from: .newlines) == nil }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

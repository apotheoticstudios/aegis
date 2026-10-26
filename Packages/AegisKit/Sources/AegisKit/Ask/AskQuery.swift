import Foundation

struct AskQuery {
    let keywords: [String]
    let schedule: Bool
    let messages: DateInterval
    let calendarWindow: DateInterval
    /// The time the words name, if they name one.
    let named: DateInterval?

    /// The search the model planned (ADR-0032), with the phrase rules' reading for anything it left open.
    init(plan: SearchPlan, rules: AskQuery, now: Date, calendar: Calendar, question: String? = nil) {
        var seen = Set<String>()
        keywords = (plan.topics.flatMap(Self.words).filter { $0.count >= 3 } + rules.keywords).filter { seen.insert($0).inserted }
        // A calendar question about something ("when's the dentist") matches titles by topic; one about a time lists it all.
        schedule = plan.places.contains(.calendar) && plan.topics.isEmpty
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
        let explicitDay = question.flatMap { Self.relativeDay(in: Self.words($0).joined(separator: " ")) }
        named = explicitDay == nil ? plan.window(now: now, calendar: calendar) : rules.named
        if let window = named {
            calendarWindow = window
            // Messages about a time to come were sent before it.
            messages = window.start >= now ? DateInterval(start: day(-14), end: now)
                : DateInterval(start: window.start, end: min(window.end, now))
        } else {
            // No time named: a topic's appointment may be months ahead.
            calendarWindow = plan.topics.isEmpty ? rules.calendarWindow : DateInterval(start: day(-30), end: day(120))
            messages = rules.messages
        }
    }

    /// Words that ask about the calendar or reminders, plurals included.
    static let scheduleWords: Set = [
        "when", "calendar", "meeting", "meetings", "appointment", "appointments", "remind", "reminder", "reminders", "due",
        "schedule", "event", "events", "agenda", "busy", "free", "booked", "diary", "upcoming", "plans", "planned", "happening",
    ]

    /// "What have I got on", "what's on", "anything coming up": the calendar, said the everyday way.
    static let schedulePhrases = [" got on ", " have on ", " what s on ", " whats on ", " anything on ", " on for ", " coming up "]

    /// This weekend (the one under way, or the next to come), or the one after it.
    static func weekend(_ now: Date, next: Bool, calendar: Calendar) -> DateInterval? {
        var weekend = calendar.isDateInWeekend(now) ? calendar.dateIntervalOfWeekend(containing: now)
            : calendar.nextWeekend(startingAfter: now)
        if next, let current = weekend {
            weekend = calendar.nextWeekend(startingAfter: current.end)
        }
        return weekend
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    init(_ question: String, now: Date, calendar: Calendar) {
        let words = Self.words(question)
        let text = " " + words.joined(separator: " ") + " "
        let stopText = "what when where who did does the about asked ask tell me my from with have has was were any there that this "
            + "and for are can could would should how why you your please today yesterday tomorrow morning tonight week last next days plans s"
        let filler = " want wants wanted need needs say says said anything something anyone someone everything get got also"
        let stop = Set((stopText + filler).split(separator: " ").map(String.init))
        var seen = Set<String>()
        keywords = words.filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
        var schedule = words.contains(where: Self.scheduleWords.contains) || Self.schedulePhrases.contains(where: text.contains)
        schedule = schedule || question.range(
            of: #"\b(?:what am i doing|what (?:do i have|have i got)(?: planned| on)?|what'?s on)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        }
        func interval(_ start: Date, _ end: Date) -> DateInterval {
            DateInterval(start: start, end: end)
        }
        var explicit: DateInterval?
        let relative = Self.relativeDay(in: text)
        if relative == "this morning" {
            explicit = interval(day(0), calendar.date(byAdding: .hour, value: 12, to: day(0))!)
        } else if relative == "tonight" {
            explicit = interval(calendar.date(byAdding: .hour, value: 18, to: day(0))!, day(1))
        } else if relative == "yesterday" {
            explicit = interval(day(-1), day(0))
        } else if relative == "tomorrow" {
            explicit = interval(day(1), day(2))
        } else if relative == "today" {
            explicit = interval(day(0), day(1))
        } else if [" the next week ", " the coming week ", " the week ahead ", " next few days ", " coming days ", " days ahead "]
            .contains(where: text.contains)
        {
            // The days ahead from now, not the calendar week after this one.
            let days = text.contains(" few days ") || text.contains(" coming days ") ? 4 : 7
            explicit = interval(now, calendar.date(byAdding: .day, value: days, to: now)!)
        } else if text.contains(" weekend "), let weekend = Self.weekend(now, next: text.contains(" next weekend "), calendar: calendar) {
            explicit = weekend
        } else if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            for (phrase, offset) in [("this week", 0), ("last week", -7), ("next week", 7)] where text.contains(" " + phrase + " ") {
                explicit = interval(
                    calendar.date(byAdding: .day, value: offset, to: week.start)!,
                    calendar.date(byAdding: .day, value: offset, to: week.end)!
                )
            }
        }
        // Matched and measured on the same string: lower-casing can change a string's length ("İ" becomes two).
        let lowered = question.lowercased()
        if explicit == nil,
           let regex = try? NSRegularExpression(pattern: #"\b(last|past|next|coming)\s+(\d+)\s+days\b"#),
           let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           let way = Range(match.range(at: 1), in: lowered), let range = Range(match.range(at: 2), in: lowered),
           let count = Int(lowered[range]), (1 ... 36500).contains(count)
        {
            let ahead = ["next", "coming"].contains(lowered[way])
            let other = calendar.date(byAdding: .day, value: ahead ? count : -count, to: now)!
            explicit = ahead ? interval(now, other) : interval(other, now)
        }
        if explicit == nil {
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            if let target = weekdays.firstIndex(where: words.contains) {
                let current = calendar.component(.weekday, from: now) - 1
                let weekday = weekdays[target]
                let next = text.contains(" next " + weekday + " ")
                let last = text.contains(" last " + weekday + " ")
                let past = words.contains { ["did", "was", "were", "sent", "received", "said"].contains($0) }
                let forward = next || (schedule && !last && !past)
                var offset = forward ? (target - current + 7) % 7 : -((current - target + 7) % 7)
                if offset == 0, next || last {
                    offset = next ? 7 : -7
                }
                explicit = interval(day(offset), day(offset + 1))
            }
        }
        // A time still to come is about the calendar, and messages about it were sent before it: they're searched over
        // the fortnight up to now rather than in the future, where there can be none.
        let lookingAhead = explicit.map { $0.start >= now.addingTimeInterval(-60) } ?? false
        // "Anything tomorrow?" is about the time itself; "dinner ideas for tonight" has a topic of its own.
        schedule = schedule || lookingAhead && keywords.isEmpty
        self.schedule = schedule
        messages = lookingAhead ? interval(calendar.date(byAdding: .day, value: -14, to: now)!, now)
            : explicit ?? interval(calendar.date(byAdding: .day, value: -7, to: now)!, now)
        calendarWindow = explicit ?? interval(
            calendar.date(byAdding: .day, value: -7, to: now)!,
            calendar.date(byAdding: .day, value: 7, to: now)!
        )
        named = explicit
    }

    /// Speech corrections use the last affirmative day, never a negated alternative (“today, not tomorrow”).
    private static func relativeDay(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:(not|except|excluding)\s+(?:for\s+)?)?(this morning|tonight|yesterday|tomorrow|today)\b"#
        ) else { return nil }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard match.range(at: 1).location == NSNotFound, let range = Range(match.range(at: 2), in: text) else { return nil }
            return String(text[range])
        }.last
    }
}

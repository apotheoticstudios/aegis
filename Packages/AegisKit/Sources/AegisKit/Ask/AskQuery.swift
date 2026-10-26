import Foundation

struct AskQuery {
    let keywords: [String]
    let schedule: Bool
    let messages: DateInterval
    let calendarWindow: DateInterval

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
        let filler = " want wants wanted need needs say says said anything something anyone someone everything get got"
        let stop = Set((stopText + filler).split(separator: " ").map(String.init))
        var seen = Set<String>()
        keywords = words.filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
        var schedule = words.contains(where: Self.scheduleWords.contains) || Self.schedulePhrases.contains(where: text.contains)
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        }
        func interval(_ start: Date, _ end: Date) -> DateInterval {
            DateInterval(start: start, end: end)
        }
        var explicit: DateInterval?
        if text.contains(" this morning ") {
            explicit = interval(day(0), calendar.date(byAdding: .hour, value: 12, to: day(0))!)
        } else if text.contains(" tonight ") {
            explicit = interval(calendar.date(byAdding: .hour, value: 18, to: day(0))!, day(1))
        } else if text.contains(" yesterday ") {
            explicit = interval(day(-1), day(0))
        } else if text.contains(" tomorrow ") {
            explicit = interval(day(1), day(2))
        } else if text.contains(" today ") {
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
    }
}

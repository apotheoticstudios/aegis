import Foundation

struct AskQuery {
    let keywords: [String]
    let schedule: Bool
    let messages: DateInterval
    let calendarWindow: DateInterval

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
        schedule = words.contains { ["when", "calendar", "meeting", "appointment", "remind", "reminder", "due", "schedule"].contains($0) }
            || text.contains("today s plans") || text.contains("tomorrow s plans")
            || question.range(
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
        } else if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            for (phrase, offset) in [("this week", 0), ("last week", -7), ("next week", 7)] where text.contains(" " + phrase + " ") {
                explicit = interval(
                    calendar.date(byAdding: .day, value: offset, to: week.start)!,
                    calendar.date(byAdding: .day, value: offset, to: week.end)!
                )
            }
        }
        if explicit == nil,
           let regex = try? NSRegularExpression(pattern: #"\blast\s+(\d+)\s+days\b"#),
           let match = regex.firstMatch(in: question.lowercased(), range: NSRange(question.startIndex..., in: question)),
           let range = Range(match.range(at: 1), in: question), let count = Int(question[range]), (1 ... 36500).contains(count)
        {
            explicit = interval(calendar.date(byAdding: .day, value: -count, to: now)!, now)
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
        messages = explicit ?? interval(calendar.date(byAdding: .day, value: -7, to: now)!, now)
        calendarWindow = explicit ?? interval(
            calendar.date(byAdding: .day, value: -7, to: now)!,
            calendar.date(byAdding: .day, value: 7, to: now)!
        )
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

import Foundation

/// All calendar arithmetic uses the caller's time zone and the promise's sent date, never today's date.
enum CommitmentDue {
    static func resolve(_ sentence: String, madeAt: Date, calendar: Calendar) -> Date? {
        let text = CommitmentText.unquoted(sentence).lowercased()
        if let interval = interval(text, madeAt: madeAt, calendar: calendar) {
            return interval
        }
        let day = day(text, madeAt: madeAt, calendar: calendar)
        if let time = time(text) {
            guard var date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day ?? madeAt) else {
                return nil
            }
            if day == nil, date < madeAt {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }
        return day.flatMap { endOfDay($0, calendar: calendar) }
    }

    private static func interval(_ text: String, madeAt: Date, calendar: Calendar) -> Date? {
        if CommitmentText.match(#"\bin (?:a (?:minute|sec|bit)|an hour)\b"#, in: text) != nil {
            return madeAt.addingTimeInterval(3600)
        }
        guard let match = CommitmentText.match(#"\bin (\d+) (minutes?|hours?|days?)\b"#, in: text),
              let count = Int(match[1]), count > 0, count <= 10000 else { return nil }
        if match[2].hasPrefix("day") {
            return calendar.date(byAdding: .day, value: count, to: madeAt)
        }
        let seconds = match[2].hasPrefix("hour") ? 3600 : 60
        return madeAt.addingTimeInterval(Double(count * seconds))
    }

    private static func day(_ text: String, madeAt: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: madeAt)
        if CommitmentText.match(#"\b(?:tomorrow|tmrw|tmr|tomoz)\b"#, in: text) != nil {
            return calendar.date(byAdding: .day, value: 1, to: start)
        }
        if CommitmentText.match(#"\b(?:this weekend|by the weekend)\b"#, in: text) != nil {
            return weekday(7, next: false, madeAt: start, calendar: calendar)
        }
        if CommitmentText.match(#"\bnext week\b"#, in: text) != nil {
            let offset = (2 - calendar.component(.weekday, from: start) + 7) % 7
            return calendar.date(byAdding: .day, value: offset == 0 ? 7 : offset, to: start)
        }
        if CommitmentText.match(#"\b(?:this week|by end of week)\b"#, in: text) != nil {
            return weekday(6, next: false, madeAt: start, calendar: calendar)
        }
        if CommitmentText.match(#"\b(?:today|tonight|this (?:morning|afternoon|evening)|by end of day|eod)\b"#, in: text) != nil {
            return start
        }
        return namedWeekday(text, madeAt: start, calendar: calendar)
    }

    private static func namedWeekday(_ text: String, madeAt: Date, calendar: Calendar) -> Date? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        guard let match = CommitmentText.match(#"\b(?:(next|on|by|this)\s+)?("# + names.joined(separator: "|") + #")\b"#, in: text),
              let index = names.firstIndex(of: match[2]) else { return nil }
        return weekday(index + 1, next: match[1] == "next", madeAt: madeAt, calendar: calendar)
    }

    private static func weekday(_ value: Int, next: Bool, madeAt: Date, calendar: Calendar) -> Date? {
        let offset = (value - calendar.component(.weekday, from: madeAt) + 7) % 7 + (next ? 7 : 0)
        return calendar.date(byAdding: .day, value: offset, to: madeAt)
    }

    private static func time(_ text: String) -> (hour: Int, minute: Int)? {
        let pattern = #"\b(?:(?:at|by)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?|"#
            + #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)|(\d{1,2}):(\d{2}))\b"#
        guard let match = CommitmentText.match(pattern, in: text) else { return nil }
        let fields: [String] = if !match[1].isEmpty {
            Array(match[1 ... 3])
        } else if !match[4].isEmpty {
            Array(match[4 ... 6])
        } else {
            [match[7], match[8], ""]
        }
        guard var hour = Int(fields[0]), let minute = Int(fields[1].isEmpty ? "0" : fields[1]), minute < 60 else { return nil }
        if !fields[2].isEmpty {
            guard (1 ... 12).contains(hour) else { return nil }
            hour = hour % 12 + (fields[2] == "pm" ? 12 : 0)
        }
        guard (0 ... 23).contains(hour) else { return nil }
        return (hour, minute)
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))?.addingTimeInterval(-1)
    }
}

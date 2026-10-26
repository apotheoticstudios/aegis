import Foundation

/// Exact calendar overviews need neither a search planner nor a generated draft or invented citations.
enum AgendaAnswer {
    struct Request {
        let window: DateInterval
        let day: String
        let remaining: Bool
        var canonical: String {
            "What is on my calendar " + day
        }
    }

    static func request(_ question: String, previous: String? = nil, now: Date, calendar: Calendar) -> Request? {
        let line = AskQuery.words(question).joined(separator: " ").replacingOccurrences(
            of: #"^(?:hey|hi|hello|yo)(?: aegis| jarvis)?\s+"#, with: "", options: .regularExpression
        ).replacingOccurrences(of: #"(?: please| mate| sir| thanks)+$"#, with: "", options: .regularExpression)
        let days = #"(today|tomorrow|yesterday|tonight|this morning)"#
        let phrase = #"^(?:what (?:have i got|do i have|am i doing)|what(?: s|s| is) (?:on(?: my calendar)?|my (?:schedule|agenda)))(?: on| planned| scheduled)?(?: for)?(?: the rest of)?(?: "#
            + days + #")?$"#
        let direct = line.range(of: phrase, options: .regularExpression) != nil
        let followUp = previous.flatMap { request($0, now: now, calendar: calendar) } != nil
            && line.range(of: #"^(?:and |what about |how about )?"# + days + #"$"#, options: .regularExpression) != nil
        guard direct || followUp else { return nil }
        let day = ["this morning", "tonight", "tomorrow", "yesterday", "today"].first { line.hasSuffix($0) } ?? "today"
        guard let window = AskQuery("calendar " + day, now: now, calendar: calendar).named else { return nil }
        return Request(window: window, day: day, remaining: line.contains("rest of"))
    }

    /// Only actual stored dates determine membership; titles and messages never establish an event's date.
    static func answer(
        _ request: Request, store: any EventStore, coverage: [SourceCoverage], now: Date, calendar: Calendar
    ) async throws -> Answer {
        let start = request.remaining ? max(now, request.window.start) : request.window.start
        let end = request.window.end
        let events = try await store.occurrences(from: start, to: end).filter {
            $0.status != .cancelled && $0.start < end && ($0.end > start || $0.start == $0.end && $0.start >= start)
        }
        let reminders = try await store.reminders(from: request.window.start, to: end).filter {
            guard !$0.isCompleted, let due = $0.due else { return false }
            return due.date >= (due.hasTime ? start : request.window.start) && due.date < end
        }
        let reminderRows: [(Date, String, String)] = reminders.compactMap { item in
            guard let due = item.due else { return nil }
            return (
                due.date,
                item.id,
                "reminder “" + title(item.title) + "”"
                    + (due.hasTime ? " due at " + clock(due.date, calendar: calendar) : " (due that day)")
            )
        }
        var rows = events.map { item in
            (
                item.start, item.id,
                "“" + title(item.title) + "” " + time(item, window: request.window, calendar: calendar)
                    + (item.status == .tentative ? " (tentative)" : "")
            )
        } + reminderRows
        rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.1).inserted }
        let shown = Array(rows.prefix(6))
        var text = shown.isEmpty
            ? "I don't have any calendar items or due reminders for \(request.day) in the records available to me."
            : "For \(request.day), your calendar and reminders list: " + shown.map(\.2).joined(separator: "; ") + "."
        if rows.count > shown.count {
            text += " There are \(rows.count - shown.count) more recorded items."
        }
        let unavailable = coverage.filter { [.calendar, .reminders].contains($0.source) && !$0.readable }
        if !unavailable.isEmpty {
            let names = unavailable.map { $0.source == .calendar ? "Calendar" : "Reminders" }.sorted().joined(separator: " and ")
            text += " \(names) isn't currently refreshing, so the saved records may be incomplete."
        }
        return Answer(text: text, eventIDs: [], scheduleIDs: shown.map(\.1), model: nil, generatedAt: now)
    }

    private static func title(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> String in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator
                ? " " : String(scalar)
        }.joined().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:ev|cal|rem|occ)_[0-9a-f]{6,}"#, with: "record", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled item" : String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(80)))
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = calendar.component(.minute, from: date) == 0 ? "ha" : "h:mma"
        return format.string(from: date).lowercased()
    }

    private static func time(_ item: CalendarOccurrence, window: DateInterval, calendar: Calendar) -> String {
        if item.isAllDay {
            return "(all day)"
        }
        if item.start < window.start || item.end > window.end {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.dateFormat = "EEE d MMM, h:mma"
            return "from " + format.string(from: item.start) + " to " + format.string(from: item.end)
        }
        return "at " + clock(item.start, calendar: calendar)
    }
}

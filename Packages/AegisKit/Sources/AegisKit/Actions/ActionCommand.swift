import Foundation

/// The owner asking Aegis to add a reminder or a calendar event (#270), parsed from their own words only, never
/// from collected content. It becomes an `ActionPayload` the owner confirms before anything is added.
public enum ActionCommand: Sendable, Equatable {
    case reminder(title: String, due: Date?)
    case event(title: String, start: Date, end: Date)
    /// "Open Spotify" (#274): an app by name; harmless, so the policy lets it happen at once.
    case openApp(name: String)
    /// "Move it to 6 pm" (#274): a new time for what Aegis just added.
    case moveLast(to: Date, allDay: Bool)
    /// "Undo that" (#274): deleting is on the never-list, so this only explains.
    case removeLast
    /// "Run the Work shortcut" (ADR-0031): one of the owner's shortcuts, by the name they said.
    case runShortcut(name: String)
    /// "Open apple.com" (ADR-0031): an http(s) address for the owner's browser.
    case openWebsite(url: String)
    /// "Open my Downloads folder" (#43): a file or folder by name; the panel finds its path before proposing anything.
    case findFile(name: String, reveal: Bool)
    /// A file or folder by its full path inside the owner's home folder (#43).
    case openFile(path: String)
    /// "Pause the music", "make a note called Groceries" (#43): one entry from the app automation catalogue.
    case automate(AppAutomation, argument: String)
    /// "Close it" (#49): quit an app Aegis just opened or controlled; the app asks about unsaved work itself.
    case quitApp(name: String)

    /// The payload the safety policy judges.
    public var payload: ActionPayload {
        switch self {
        case let .reminder(title, due): .reminder(title: title, due: due)
        case let .event(title, start, end): .calendar(title: title, start: start, end: end)
        case let .openApp(name): .app(bundleID: name, verb: .open)
        case let .moveLast(date, _): .reminder(title: "", due: date, verb: .edit)
        case .removeLast: .reminder(title: "", due: nil, verb: .delete)
        case let .runShortcut(name): .shortcut(name: name)
        case let .openWebsite(url): .website(url: url)
        case let .findFile(name, _): .file(path: name, verb: .read)
        case let .openFile(path): .file(path: path, verb: .open)
        case let .automate(entry, argument): .automation(entry, argument: argument)
        case let .quitApp(name): .app(bundleID: name, verb: .close)
        }
    }

    /// "Add reminder “Call Mum”, today at 5:00 pm?" for the confirmation card.
    public func summary(calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case let .reminder(title, due):
            "Add the reminder “\(title)”" + (due.map { ", " + Self.when($0, calendar: calendar, locale: locale) } ?? "") + "?"
        case let .event(title, start, end):
            "Add “\(title)” to your calendar, " + Self.when(start, calendar: calendar, locale: locale) + " to "
                + Self.time(end, calendar: calendar, locale: locale) + "?"
        case let .openApp(name):
            "Open \(name)?"
        case let .moveLast(date, allDay):
            "Move it to " + (allDay ? Self.day(date, calendar: calendar, locale: locale)
                : Self.when(date, calendar: calendar, locale: locale)) + "?"
        case .removeLast:
            "Remove it?"
        case let .runShortcut(name):
            "Run the shortcut “\(name)”?"
        case let .openWebsite(url):
            "Open " + Self.bare(url) + "?"
        case let .openFile(name), let .findFile(name, false): "Open “" + URL(fileURLWithPath: name).lastPathComponent + "”?"
        case let .findFile(name, true): AppAutomation.finderReveal.summary(name)
        case let .automate(entry, argument): entry.summary(argument)
        case let .quitApp(name): "Quit \(name)?"
        }
    }

    public static func parse(_ text: String, now: Date, calendar: Calendar) -> ActionCommand? {
        let line = cleaned(text)
        guard !line.isEmpty, line.count <= 200 else { return nil }
        if let other = followUp(line, now: now, calendar: calendar) {
            return other
        }
        if let rest = capture(
            #"^(?:remind me(?: to)?|set (?:a|an) reminder(?: to)?|add (?:a )?reminder(?: to)?|reminder:?)\s+(.+)$"#,
            line
        ) {
            let (title, when) = split(rest, now: now, calendar: calendar)
            guard !title.isEmpty else { return nil }
            return .reminder(title: title, due: when?.reminder)
        }
        return event(line, now: now, calendar: calendar)
    }

    /// The owner's line without "hey Aegis", "please" or a trailing full stop.
    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .replacingOccurrences(of: #"[\s.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",?\s*please$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func event(_ line: String, now: Date, calendar: Calendar) -> ActionCommand? {
        if line
            .range(of: #"\b(?:calendar|diary|schedule|appointment|meeting|event)\b"#, options: [.regularExpression, .caseInsensitive]) !=
            nil,
            let body = capture(#"^(?:add|put|schedule|book|create|make)\s+(.+)$"#, line)
        {
            let cleaned = body
                .replacingOccurrences(
                    of: #"\s+(?:to|in|on|into) (?:my |the )?(?:calendar|diary)\b"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"^an? (?:event|appointment) (?:for|called) "#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(of: #"^an? "#, with: "", options: [.regularExpression, .caseInsensitive])
            let (title, when) = split(cleaned, now: now, calendar: calendar)
            guard !title.isEmpty, let when, when.hasTime || when.allDay else { return nil }
            let start = when.date
            let end = when.allDay ? start.addingTimeInterval(86400) : start.addingTimeInterval(when.minutes * 60)
            return .event(title: title, start: start, end: end)
        }
        return nil
    }

    /// Websites, shortcuts, the app catalogue, files and apps, and moving or undoing what Aegis just added.
    private static func followUp(_ line: String, now: Date, calendar: Calendar) -> ActionCommand? {
        if let command = catalogue(line) {
            return command
        }
        let site = #"^(?:open|go to|visit|take me to|load|pull up|bring up|browse to|navigate to)(?: up)?(?: the)?"#
            + #"(?: (?:website|site|web ?page|page))? (.+?)(?: in (?:the )?(?:browser|safari|chrome|firefox))?$"#
        if let address = capture(site, line).flatMap(website) {
            return .openWebsite(url: address)
        }
        let verbs = #"^(?:run|start|do|launch|open|trigger|use|activate) (?:the |my )?"#
        if let name = capture(verbs + #"shortcut (?:called |named )?(.+)$"#, line) ?? capture(verbs + #"(.+?) shortcut$"#, line) {
            return .runShortcut(name: name)
        }
        if let app = capture(#"^(?:open|launch|start|run|bring up) (?:up )?(?:the )?(?:app )?(.+?)(?: app)?$"#, line), app.count <= 40,
           app
           .range(of: #"\b(?:world|globe|view|panel|brief|reminders? for)\b"#, options: [.regularExpression, .caseInsensitive]) ==
           nil
        {
            return .openApp(name: app)
        }
        let move = #"^(?:move|change|push|make|reschedule|shift) (?:it|that|the (?:reminder|event|appointment|meeting|last one))"#
            + #"(?: (?:to|for|until))? (.+)$"#
        if let rest = capture(move, line) {
            let (_, when) = split(rest, now: now, calendar: calendar)
            guard let when else { return nil }
            return .moveLast(to: when.hasTime ? when.reminder : when.date, allDay: !when.hasTime)
        }
        let undo = #"^(?:undo|delete|remove|cancel|get rid of) (?:that|it|this|the last (?:one|reminder|event))$|^undo$"#
        if line.range(of: undo, options: [.regularExpression, .caseInsensitive]) != nil {
            return .removeLast
        }
        return nil
    }

    /// "apple.com", "apple dot com/store", "www.bom.gov.au": an http(s) address, or nil when it isn't one.
    /// File-like endings ("Notes.app", "notes.md") aren't websites.
    public static func website(_ text: String) -> String? {
        let spoken = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
        let pattern = #"^(?:(https?)://)?((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,24}))(?::\d{1,5})?([/?#][^\s]*)?$"#
        guard let match = firstMatch(pattern, spoken.lowercased()),
              !fileEndings.contains(match.groups[2])
        else { return nil }
        let rest = String(spoken.dropFirst(match.groups[0].isEmpty ? 0 : match.groups[0].count + 3))
        let address = (match.groups[0].isEmpty ? "https" : match.groups[0]) + "://" + rest
        return URL(string: address) == nil ? nil : address
    }

    private static func day(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        when(date, calendar: calendar, locale: locale).replacingOccurrences(of: #" at .*$"#, with: "", options: .regularExpression)
    }

    // MARK: - Dates and times

    struct When {
        var date: Date
        var hasTime: Bool
        var allDay: Bool
        var minutes: Double
        /// When a reminder is due: the time, or 9 am on a date given without one.
        var reminder: Date
    }

    /// Splits "call Mum tomorrow at 5pm" into ("call Mum", tomorrow 17:00). Times without a date are today, or
    /// tomorrow if already past; dates without a time are 9 am for reminders (all day for events).
    static func split(_ text: String, now: Date, calendar: Calendar) -> (String, When?) {
        var rest = " " + text + " "
        let duration = takeDuration(&rest)
        if let seconds = takeDelay(&rest) {
            let date = now.addingTimeInterval(seconds)
            return (tidy(rest), When(date: date, hasTime: true, allDay: false, minutes: duration, reminder: date))
        }
        var clock = takeTime(&rest)
        let start = calendar.startOfDay(for: now)
        let (day, partOfDay) = takeDay(&rest, start: start, calendar: calendar)
        if clock == nil, let partOfDay {
            clock = (partOfDay, 0)
        }
        let title = tidy(rest)
        guard day != nil || clock != nil else { return (title, nil) }
        var base = day ?? start
        if let (hour, minute) = clock {
            base = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
            if day == nil, base <= now {
                base = calendar.date(byAdding: .day, value: 1, to: base) ?? base
            }
            return (title, When(date: base, hasTime: true, allDay: false, minutes: duration, reminder: base))
        }
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
        return (title, When(date: base, hasTime: false, allDay: true, minutes: duration, reminder: nine))
    }

    /// "for 2 hours", "for 30 minutes": the event's length in minutes (an hour when not said).
    private static func takeDuration(_ rest: inout String) -> Double {
        guard let match = firstMatch(#"\s+for (\d+(?:\.\d+)?|an?|half an) (hours?|hrs?|minutes?|mins?)\b"#, rest.lowercased()) else {
            return 60
        }
        rest = remove(match.range, from: rest)
        return amount(match.groups[0]) * (match.groups[1].hasPrefix("h") ? 60 : 1)
    }

    /// "in 20 minutes", "in 2 hours": seconds from now.
    private static func takeDelay(_ rest: inout String) -> Double? {
        guard let match = firstMatch(#"\s+in (\d+|an?|half an) (hours?|hrs?|minutes?|mins?)\b"#, rest.lowercased()) else { return nil }
        rest = remove(match.range, from: rest)
        return amount(match.groups[0]) * (match.groups[1].hasPrefix("h") ? 3600 : 60)
    }

    private static func amount(_ word: String) -> Double {
        word == "half an" ? 0.5 : word.hasPrefix("a") ? 1 : Double(word) ?? 1
    }

    /// "at 5" (1 to 6 are afternoon), "5pm", "5:30 pm", "at 17:00", "noon", "midnight".
    private static func takeTime(_ rest: inout String) -> (Int, Int)? {
        let pattern = #"\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?=\s)|\s+at\s+(\d{1,2})(?::(\d{2}))?(?=\s)|"#
            + #"\s+(?:at\s+)?(noon|midday|midnight)(?=\s)"#
        guard let match = firstMatch(pattern, rest.lowercased()) else { return nil }
        let groups = match.groups
        var clock: (Int, Int)?
        if !groups[5].isEmpty {
            clock = (groups[5] == "midnight" ? 0 : 12, 0)
        } else if var hour = Int(groups[0]), hour <= 12 {
            if groups[2].hasPrefix("p"), hour < 12 {
                hour += 12
            }
            if groups[2].hasPrefix("a"), hour == 12 {
                hour = 0
            }
            clock = (hour, Int(groups[1]) ?? 0)
        } else if var hour = Int(groups[3]), hour <= 23 {
            if (1 ... 6).contains(hour) {
                hour += 12
            }
            clock = (hour, Int(groups[4]) ?? 0)
        }
        if clock != nil {
            rest = remove(match.range, from: rest)
        }
        return clock
    }

    /// The day, and an hour for "tonight" or "tomorrow morning".
    private static func takeDay(_ rest: inout String, start: Date, calendar: Calendar) -> (Date?, Int?) {
        let lower = rest.lowercased()
        if let match = firstMatch(
            #"\s+(today|tonight|this (?:morning|afternoon|evening)|tomorrow(?: (?:morning|afternoon|evening|night))?)(?=\s)"#,
            lower
        ) {
            rest = remove(match.range, from: rest)
            let word = match.groups[0]
            let day = word.hasPrefix("tomorrow") ? calendar.date(byAdding: .day, value: 1, to: start) : start
            let hour: Int? = word.contains("morning") ? 9 : word.contains("afternoon") ? 14
                : word.contains("evening") || word.contains("night") ? 19 : nil
            return (day, hour)
        }
        if let match = firstMatch(
            #"\s+(?:on |this |next )?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu|thurs?|fri|sat|sun)(?=\s)"#,
            lower
        ) {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            guard let target = names.firstIndex(where: { match.groups[0].hasPrefix($0) }) else { return (nil, nil) }
            rest = remove(match.range, from: rest)
            let today = calendar.component(.weekday, from: start) - 1
            let ahead = (target - today + 7) % 7 == 0 ? 7 : (target - today + 7) % 7
            return (calendar.date(byAdding: .day, value: ahead, to: start), nil)
        }
        let pattern = #"\s+(?:on )?(?:the )?(\d{1,2})(?:st|nd|rd|th)?(?: of)? (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*(?=\s)|"#
            + #"\s+(?:on )?(\d{1,2})/(\d{1,2})(?=\s)"#
        guard let match = firstMatch(pattern, lower) else { return (nil, nil) }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let groups = match.groups
        guard let number = Int(groups[0].isEmpty ? groups[2] : groups[0]),
              let month = groups[1].isEmpty ? Int(groups[3]) : months.firstIndex(of: groups[1]).map({ $0 + 1 })
        else { return (nil, nil) }
        let year = calendar.component(.year, from: start)
        var date = calendar.date(from: DateComponents(year: year, month: month, day: number))
        if let found = date, found < start {
            date = calendar.date(from: DateComponents(year: year + 1, month: month, day: number))
        }
        guard let date, calendar.component(.day, from: date) == number else { return (nil, nil) }
        rest = remove(match.range, from: rest)
        return (date, nil)
    }

    private static func tidy(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.")))
            .replacingOccurrences(of: #"^(?:to |that |about )"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(?:on|at|for|by)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    private struct Match {
        let range: Range<String.Index>
        let groups: [String]
        let full: String
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        let groups = (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        return Match(range: range, groups: groups, full: String(text[range]))
    }

    /// Removes a range found in the lowercased copy (same length: ASCII patterns) and keeps a space.
    private static func remove(_ range: Range<String.Index>, from text: String) -> String {
        let lower = text.lowercased()
        let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let length = lower.distance(from: range.lowerBound, to: range.upperBound)
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: length)
        return text.replacingCharacters(in: from ..< to, with: " ")
    }

    static func capture(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func when(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = locale
        let start = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: date)
        let prefix = day == start ? "today" : day == calendar.date(byAdding: .day, value: 1, to: start) ? "tomorrow" : {
            format.dateFormat = "EEEE d MMMM"
            return format.string(from: date)
        }()
        return prefix + " at " + time(date, calendar: calendar, locale: locale)
    }

    private static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = locale
        format.dateFormat = "h:mm a"
        return format.string(from: date).lowercased()
    }
}

/// The owner's answer to an action card (#274): yes, no, or neither.
public enum ActionReply {
    public static func parse(_ text: String) -> Bool? {
        let line = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
        let yes = #"^(?:yes|yeah|yep|yup|sure|ok|okay|do it|add it|go ahead|confirm|please do|sounds good|that's right|correct|"#
            + #"yes please|yes add it|yes do it|go for it|open it|move it|run it|yes run it|yes open it|go|go on)$"#
        if line.range(of: yes, options: .regularExpression) != nil {
            return true
        }
        if line.range(
            of: #"^(?:no|nope|nah|cancel|cancel it|never ?mind|don't|do not|stop|forget it|no thanks|no cancel|leave it)$"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        return nil
    }
}

import Foundation

enum AskRetrieval {
    struct Line {
        let id: String
        let text: String
        let schedule: Bool
    }

    static func prepare(
        question: String, now: Date, calendar: Calendar, store: any EventStore, contacts: ContactIndex?,
        model: (any ModelClient)? = nil, check: AskSemantic.RelevanceCheck? = nil
    ) async throws -> AskInput {
        let question = AskSelection.requestText(question)
        let query = AskQuery(question, now: now, calendar: calendar)
        let window = query.messages
        let selection = AskSelection(question, query: query)
        func resolve(_ events: [Event]) -> [Event] {
            contacts.map { resolveSenders(events, index: $0) } ?? events
        }
        let people = contacts?.people(mentionedIn: question)
        if people?.ambiguous == true {
            var input = AskInput(text: "", eventIDs: [], scheduleIDs: [])
            input.directAnswer = "Which person do you mean? Please use their full name or another identifying detail."
            return input
        }
        let senderIDs = selection.sender.flatMap { contacts?.people(mentionedIn: $0).ids } ?? []
        let namedPerson = people?.ids.isEmpty == false
        func person(_ event: Event) -> Bool {
            guard let id = event.senderContact?.id else { return false }
            return people?.ids.contains(id) == true
        }
        var mentionedNameWords = Set<String>()
        var candidates: [String: Event] = [:]
        // "What did Alex ask / want?": only Alex's questions, so they aren't buried in everything else.
        let askIntent = ["ask", "asked", "asking", "want", "wants", "wanted", "need", "needs", "request", "requested"]
            .contains(where: AskQuery.words(question).contains)
        let onlySender = namedPerson && (askIntent || ["say", "says", "said", "tell", "told", "sent", "wrote", "write"]
            .contains(where: AskQuery.words(question).contains))
        let useMeaning = model != nil && !selection.overview && !selection.translating && !selection.terms.isEmpty
            && (selection.source != nil || onlySender) && !(query.schedule && selection.source == nil)
            && !Chat.isRequestToAct(question)
        var semanticPool: [Event] = []
        // Page the window so a named person's recent records cannot be hidden by an older first page.
        var cursor: EventCursor?
        while true {
            let page = try await store.events(from: window.start, to: window.end, after: cursor, limit: 1000)
            let resolved = resolve(page)
            if useMeaning {
                semanticPool = AskSemantic.pool(semanticPool + resolved.filter {
                    $0.eventTime >= window.start && $0.eventTime < window.end
                        && selection.matches($0, senderIDs: senderIDs)
                        && (!onlySender || person($0) && (!askIntent || BriefInputPolicy.asksOwner($0)))
                }, terms: selection.terms)
            }
            for event in resolved where selection.matches(event, senderIDs: senderIDs)
                && ((person(event) && (!askIntent || BriefInputPolicy.asksOwner(event))) || selection.sender != nil || selection.overview)
            {
                candidates[event.id] = event
            }
            trimCandidates(&candidates, terms: selection.terms)
            guard let last = page.last, page.count == 1000 else { break }
            let next = EventCursor(after: last)
            guard next != cursor else { break }
            cursor = next
        }
        for event in candidates.values where onlySender && person(event) {
            mentionedNameWords.formUnion(AskQuery.words(event.senderContact?.name ?? ""))
        }
        // A named person selects their messages; their name is not a search word (owner's test questions).
        let searchWords = selection.terms.filter { !mentionedNameWords.contains($0) }
        if !searchWords.isEmpty {
            func include(_ results: [Event]) {
                for event in resolve(results) where selection.matches(event, senderIDs: senderIDs) && (!onlySender || person(event)) {
                    candidates[event.id] = event
                }
                trimCandidates(&candidates, terms: selection.terms)
            }
            let results = try await store.search(searchWords.joined(separator: " "), from: window.start, to: window.end, limit: 100)
            include(results)
            if results.count < 5 {
                for word in searchWords {
                    try await include(store.search(word, from: window.start, to: window.end, limit: 100))
                }
            }
        }

        let semantic = if useMeaning, let model {
            await AskSemantic.matches(semanticPool, terms: searchWords, model: model, check: check)
        } else {
            [Event]()
        }
        for event in semantic {
            candidates[event.id] = event
        }

        // Notification twins merge into their Messages records, so answers cite the conversation (#153).
        let merged = try EventMerger.merge(candidates.values.sorted { $0.eventTime < $1.eventTime })
        // Planted orders to an assistant are never an answer: they stay out of the context entirely.
        let matched = merged.filter { $0.eventTime >= window.start && $0.eventTime < window.end && !BriefLayout.plantedOrder($0) }
        let ranked = AskSemantic.ordered(matched, semantic: semantic) {
            keywordRank($0, keywords: searchWords) + (person($0) ? 1 : 0)
        }
        let events = Array(ranked.prefix(selection.singleTranslation ? 1 : 25))
        var lines = eventLines(events, calendar: calendar, terms: searchWords)
        let schedules = (onlySender && !query.schedule) || selection.source != nil || selection
            .direction != nil ? [] : try await scheduleLines(
                query: query,
                store: store,
                calendar: calendar,
                includeAll: selection.overview
            )
        lines = query.schedule ? schedules + lines : lines + schedules
        let task = AskSemantic.question(question, hasMatches: !semantic.isEmpty)
        return try finalized(
            assemble(lines, question: selection.modelQuestion(task), now: now, calendar: calendar),
            selection: selection,
            namedPerson: namedPerson,
            grounded: selection.isReadRequest || onlySender || query.schedule
        )
    }

    private static func finalized(_ input: AskInput, selection: AskSelection, namedPerson: Bool, grounded: Bool) -> AskInput {
        var input = input
        input.prefersGrounded = grounded
        if selection.isReadRequest, input.isEmpty {
            input.directAnswer = "I couldn't find matching " + (selection.source == .mail ? "email" : "records")
                + " for that time in what I have available."
        } else if namedPerson, input.isEmpty {
            input.directAnswer = Ask.notFound
        }
        return input
    }

    private static func eventLines(_ events: [Event], calendar: Calendar, terms: [String]) -> [Line] {
        events.map {
            Line(id: $0.id, text: line($0, calendar: calendar, bodyLimit: events.count == 1 ? 3600 : 600, terms: terms), schedule: false)
        }
    }

    /// Calendar occurrences and reminders for the question's calendar window: at most 10, soonest first.
    private static func scheduleLines(
        query: AskQuery,
        store: any EventStore,
        calendar: Calendar,
        includeAll: Bool = false
    ) async throws -> [Line] {
        let scheduleWindow = query.calendarWindow
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMM yyyy, h:mm a"
        func date(_ date: Date, allDay: Bool = false) -> String {
            formatter.dateFormat = allDay ? "d MMM yyyy (all-day)" : "EEE, d MMM yyyy, h:mm a"
            return formatter.string(from: date)
        }
        func matches(_ title: String) -> Bool {
            includeAll || query.schedule || query.keywords.contains { title.lowercased().contains($0) }
        }
        func quoted(_ text: String) -> String {
            jsonString(String(text.unicodeScalars.prefix(400)))
        }
        var scheduleLines: [(Date, Line)] = []
        for item in try await store.occurrences(from: scheduleWindow.start, to: scheduleWindow.end)
            where item.start < scheduleWindow
            .end && (item.end > scheduleWindow.start || item.start >= scheduleWindow.start) && matches(item.title)
        {
            let time = item.isAllDay
                ? date(item.start, allDay: true) + "…" + date(item.end, allDay: true) + " (end exclusive)"
                : date(item.start) + "…" + date(item.end)
            let location = item.location.map { " · " + quoted($0) } ?? ""
            scheduleLines.append((
                item.start,
                Line(
                    id: item.id,
                    text: "[\(item.id)] \(time) · \(quoted(item.title))\(location)\(EventEvidence.attendees(item))",
                    schedule: true
                )
            ))
        }
        for item in try await store.reminders(from: scheduleWindow.start, to: scheduleWindow.end) where matches(item.title) {
            guard let stamp = item.isCompleted ? item.completedAt : item.due?.date,
                  stamp >= scheduleWindow.start, stamp < scheduleWindow.end else { continue }
            let time = date(stamp, allDay: item.due?.hasTime == false)
            scheduleLines.append((
                stamp,
                Line(
                    id: item.id,
                    text: "[\(item.id)] \(time) · \(quoted(item.title)) · \(item.isCompleted ? "completed" : "due")",
                    schedule: true
                )
            ))
        }
        return Array(scheduleLines.sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }.prefix(10).map(\.1))
    }

    /// One context line in plain words, so a small model can't mistake a question for a fact:
    /// `[id] Tue 7 Oct, 14:05 · SMS · Robin Example asked you: "Did the parcel arrive?"`.
    static func line(_ event: Event, calendar: Calendar, bodyLimit: Int = 280, terms: [String] = []) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM, h:mm a"
        let source = switch event.source {
        case .imessage: "iMessage"
        case .sms: "SMS"
        case .email: "Email"
        case .notification: "Notification"
        }
        let outgoing = SenderDisplay.isOutgoing(event)
        let who = outgoing ? "You" : (BriefLayout.speaker(event) ?? "Someone")
        let verb = outgoing ? "wrote" : (BriefInputPolicy.asksOwner(event) ? "asked you" : "wrote")
        var context = ""
        if let title = event.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty, title != who {
            context = event
                .source == .email ? " · subject \(jsonString(title))" :
                (event.threadID?.contains(";+;") == true ? " · in \(jsonString(title))" : "")
        }
        let excerpt = AskExcerpt.text(event.body, limit: bodyLimit, terms: terms)
        let body = event.body.isEmpty ? "(no text)" : jsonString(excerpt)
        if excerpt != event.body {
            context += " · body excerpt (not the full message)"
        }
        if event.content != .complete || event.flags.contains(.truncated) {
            context += " · source text incomplete"
        }
        return "[\(event.id)] \(formatter.string(from: event.eventTime)) · \(source) · \(who) \(verb): \(body)\(context)\(EventEvidence.metadata(event))"
    }

    private static func trimCandidates(_ candidates: inout [String: Event], terms: [String]) {
        guard candidates.count > 500 else { return }
        let best = candidates.values.sorted {
            let left = keywordRank($0, keywords: terms), right = keywordRank($1, keywords: terms)
            if left != right {
                return left > right
            }
            return ($0.eventTime, $0.id) > ($1.eventTime, $1.id)
        }.prefix(500)
        candidates = Dictionary(uniqueKeysWithValues: best.map { ($0.id, $0) })
    }

    private static func keywordRank(_ event: Event, keywords: [String]) -> Int {
        let text = [event.sender, event.senderContact?.name, event.title, event.body].compactMap(\.self)
            .joined(separator: " ").lowercased()
        return keywords.reduce(0) { $0 + (text.contains($1) ? ($1.contains(where: \.isNumber) ? 4 : 2) : 0) }
    }

    static func assemble(_ lines: [Line], question: String, now: Date, calendar: Calendar) throws -> AskInput {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE, d MMM yyyy, h:mm a"
        let header = "Today is \(formatter.string(from: now)) (\(calendar.timeZone.identifier)).\nQuestion: "
            + jsonString(question) + "\nContext (a bounded selection of available records, not a complete inbox or day):"
        guard header.unicodeScalars.count < 8000 else { throw PipelineError.invalidPolicy }
        var count = header.unicodeScalars.count
        var included: [Line] = []
        for line in lines {
            let size = line.text.unicodeScalars.count + 1
            guard count + size < 8000 else { break }
            included.append(line)
            count += size
        }
        return AskInput(
            text: ([header] + included.map(\.text)).joined(separator: "\n"),
            eventIDs: included.filter { !$0.schedule }.map(\.id),
            scheduleIDs: included.filter(\.schedule).map(\.id)
        )
    }
}

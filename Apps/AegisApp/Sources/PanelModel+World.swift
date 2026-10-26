import AegisKit
import Foundation

/// World commands from the Ask bar or voice (#265): "show flights over Brisbane", "where's the ISS?".
extension PanelModel {
    /// The answer to a World command, or nil when the question isn't one.
    func worldAnswer(_ question: String) async -> Answer? {
        // Reminders and calendar events come first (#270).
        if let action = await actionAnswer(question) {
            return action
        }
        let world = WorldWindow.shared
        guard let command = WorldCommand.parse(
            question, worldOpen: world.isOpen, homeCity: WorldWindow.homeCity, lastPlace: world.recentPlace
        )
        else {
            if let plan = await worldPlanAnswer(question) {
                return plan
            }
            guard let command = await commandPlanAnswer(question) else {
                // Not a command: "again" is now the chat's own (#49).
                ActionPresence.shared.chattedSince = true
                return nil
            }
            return command
        }
        let service = service
        let text = await WorldWindow.shared.run(command) {
            // The next four weeks, a week at a time (the schedule request's limit).
            var events: [CalendarOccurrence] = []
            let start = Date()
            for week in 0 ..< 4 {
                let from = start.addingTimeInterval(Double(week) * 7 * 86400)
                if case let .schedule(occurrences, _) = await service.handle(.schedule(
                    from: from,
                    to: from.addingTimeInterval(7 * 86400)
                )) {
                    events += occurrences
                }
            }
            return Array(Set(events))
        }
        return Answer(text: text, eventIDs: [], scheduleIDs: [], model: "world", generatedAt: Date())
    }

    /// Anything else God's Eye View can do (#296): while the globe is open, the local model picks from its own actions.
    /// Nil when the globe is closed or the request isn't for the globe, so the question is asked as usual.
    private func worldPlanAnswer(_ question: String) async -> Answer? {
        guard WorldWindow.shared.isOpen, MemoryCommand.parse(question) == nil,
              QuickAnswer.answer(question, now: Date(), calendar: .current) == nil,
              case let .worldPlan(actions, say) = await service.handle(.worldPlan(question: question)), !actions.isEmpty
        else { return nil }
        let text = await WorldWindow.shared.run(actions, fallback: say)
        return Answer(text: text, eventIDs: [], scheduleIDs: [], model: "world", generatedAt: Date())
    }

    /// Weather at home and today's flight for the brief (#265): public data, at most every 30 minutes, only while
    /// the panel is open. Home goes out rounded to about 10 km, a flight as its callsign.
    func refreshWorldBrief() async {
        // App tests run inside Aegis: they stay offline and never send the owner's home.
        guard !WorldSidecar.isTestHost else { return }
        // Refreshes also run at launch and in the background: no globe server or public data with the panel closed.
        guard HUDPresence.shared.open else { return }
        WorldWindow.shared.prewarm()
        let world = WorldPresence.shared
        guard WorldPresence.briefEnabled else {
            world.briefLines = []
            return
        }
        guard Date().timeIntervalSince(world.briefFetched) > 1800 else { return }
        world.briefFetched = Date()
        let session = URLSession(configuration: .ephemeral) // privacy-guard: allow-network public weather and flight status, ADR-0024
        var lines: [String] = []
        if let home = WorldHome.point, let url = WorldBrief.weatherURL(latitude: home.latitude, longitude: home.longitude),
           let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
           let weather = WorldBrief.weather(data, now: Date())
        {
            lines.append(weather)
        }
        if let home = WorldHome.point {
            lines += await WorldFeeds.briefLines(home)
        }
        let now = Date()
        if case let .schedule(occurrences, _) = await service.handle(.schedule(
            from: now.addingTimeInterval(-6 * 3600),
            to: now.addingTimeInterval(24 * 3600)
        )),
            let flight = OwnerPlaces.nextFlight(occurrences.filter { $0.start <= now.addingTimeInterval(24 * 3600) }, now: now),
            let url = WorldBrief.flightURL(callsign: flight.callsign)
        {
            let data = try? await session.data(from: url).0
            lines.append(WorldBrief.flight(data, number: flight.number, start: flight.start, now: now, calendar: .current))
        }
        world.briefLines = lines
    }
}

import Foundation

extension CoreEngine {
    /// Read-only promise and completion endpoints, kept out of the main dispatch switch.
    func completionResponse(_ request: CoreRequest) async -> CoreResponse? {
        switch request {
        case .commitments: await commitments()
        case .done: await done()
        default: nil
        }
    }

    /// Today's completions, using the same named, merged and visible history as `people()` and commitments.
    func done() async -> CoreResponse {
        do {
            let now = clock()
            let start = calendar.startOfDay(for: now)
            // Store windows are half-open. Include exact boundary records; compute removes anything outside today so far.
            let end = now.addingTimeInterval(1)
            let history = try await allEvents(from: now.addingTimeInterval(-7 * 86400), to: end)
            let events = try await EventMerger.merge(named(history.filter { $0.eventTime <= now }))
            let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let occurrences = try await store.occurrences(from: start.addingTimeInterval(-1), to: end)
            let reminders = try await store.reminders(from: start, to: end)
            let muted = Set(rules.muted.keys)
            let items = DoneToday.compute(
                events: rules.visible(events), occurrences: occurrences, reminders: reminders, contacts: BriefLayout.contactIDs(byID),
                now: now, calendar: calendar, maxItems: Int.max
            ).filter { item in
                item.personID.map { !muted.contains($0) } ?? true
            }
            return .done(Array(items.prefix(20)))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }
}

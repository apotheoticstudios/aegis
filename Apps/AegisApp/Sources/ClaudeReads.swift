import AegisKit
import Foundation

/// Claude's read tools, answered from AegisCore's existing read-only requests (ADR-0038 §5). `ClaudeTools` decides
/// what may go under the owner's switches; this only fetches.
struct ClaudeReads: ClaudeToolSource {
    private static let categoriesKey = "claudeReadCategories"

    /// The categories the owner has left on: all of them unless switched off.
    static var enabled: Set<ClaudeTools.Category> {
        get {
            guard let names = UserDefaults.aegis.stringArray(forKey: categoriesKey) else { return Set(ClaudeTools.Category.allCases) }
            return Set(names.compactMap(ClaudeTools.Category.init(rawValue:)))
        }
        set { UserDefaults.aegis.set(newValue.map(\.rawValue).sorted(), forKey: categoriesKey) }
    }

    let service: any CoreService

    func fetch(_ call: ClaudeTools.Call, enabled: Set<ClaudeTools.Category>) async -> ClaudeTools.Payload {
        // The owner's switches as they are now: one turned off mid-run applies to the next result.
        let enabled = enabled.intersection(Self.enabled)
        switch call {
        case let .recentItems(limit):
            guard case let .events(events) = await service.handle(.recentEvents(limit: limit)) else { return Self.unavailable }
            return ClaudeTools.items(events, enabled: enabled)
        case let .readItems(ids):
            guard case let .events(events) = await service.handle(.sources(ids: ids)) else { return Self.unavailable }
            return ClaudeTools.items(events, enabled: enabled)
        case let .schedule(daysBack, daysAhead):
            let start = Calendar.current.startOfDay(for: Date())
            let from = Calendar.current.date(byAdding: .day, value: -daysBack, to: start) ?? start
            // A daylight-saving change can lengthen the days; AegisCore takes at most `maxScheduleDays` × 24 hours.
            let end = Calendar.current.date(byAdding: .day, value: daysAhead + 1, to: start) ?? start
            let to = min(end, from.addingTimeInterval(Double(CoreRequest.maxScheduleDays) * 86400))
            guard case let .schedule(occurrences, reminders) = await service.handle(.schedule(from: from, to: to)) else {
                return Self.unavailable
            }
            return ClaudeTools.schedule(occurrences, reminders, enabled: enabled)
        case .brief:
            guard case let .brief(stored) = await service.handle(.latestBrief) else { return Self.unavailable }
            let cited = stored?.brief.items.flatMap(\.eventIDs) ?? []
            return await ClaudeTools.brief(stored, sources: sources(of: cited), enabled: enabled)
        case .peopleWaiting:
            guard case let .people(people) = await service.handle(.people) else { return Self.unavailable }
            return await ClaudeTools.people(people, sources: sources(of: people.flatMap(\.eventIDs)), enabled: enabled)
        case .promises:
            guard case let .commitments(promises) = await service.handle(.commitments) else { return Self.unavailable }
            return await ClaudeTools.promises(promises, sources: sources(of: promises.map(\.eventID)), enabled: enabled)
        case .doneToday:
            guard case let .done(items) = await service.handle(.done) else { return Self.unavailable }
            return await ClaudeTools.done(items, sources: sources(of: items.flatMap(\.eventIDs)), enabled: enabled)
        case .memoryNotes:
            guard case let .memories(notes) = await service.handle(.memories) else { return Self.unavailable }
            return ClaudeTools.memories(notes, enabled: enabled)
        case .act:
            return .refused("Aegis doesn't act on this request.")
        case .sourceHealth:
            guard case let .status(status) = await service.handle(.status) else { return Self.unavailable }
            return ClaudeTools.health(status, enabled: enabled)
        }
    }

    private static let unavailable = ClaudeTools.Payload.refused("Aegis couldn't read that just now.")

    /// Where each cited item came from, asked of AegisCore in batches. An ID it doesn't return stays unknown, so an
    /// item citing it is left out.
    func sources(of ids: [String]) async -> [String: ClaudeTools.Category] {
        var unique: [String] = []
        for id in ids where !unique.contains(id) && unique.count < ClaudeTools.maxCited {
            unique.append(id)
        }
        var found: [String: ClaudeTools.Category] = [:]
        for start in stride(from: 0, to: unique.count, by: CoreRequest.maxSourceIDs) {
            let batch = Array(unique[start ..< min(start + CoreRequest.maxSourceIDs, unique.count)])
            guard case let .events(events) = await service.handle(.sources(ids: batch)) else { continue }
            for event in events {
                found[event.id] = ClaudeTools.Category(event.source)
            }
        }
        return found
    }
}

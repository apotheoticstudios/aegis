import AegisKit
import Foundation

/// The last day of collection counts for the HOME and COMMS charts (#8): counts only, kept in memory.
@MainActor @Observable
final class ActivityPresence {
    static let shared = ActivityPresence()
    var latest: HourlyActivity?

    /// One source's counts for the day, oldest hour first; zeros when it had none.
    func hours(_ sources: [Event.Source]) -> [Double] {
        guard let latest else { return [] }
        let empty = Array(repeating: 0, count: CoreRequest.maxActivityHours)
        return sources.map { latest.counts[$0] ?? empty }.reduce(empty.map(Double.init)) { sum, counts in
            zip(sum, counts + empty).map { $0 + Double($1) }
        }
    }

    /// Every source together, hour by hour.
    var total: [Double] {
        hours(Event.Source.allCases)
    }

    /// The hours since midnight in `hours(sources)`, oldest first; none when the counts are from a day that has ended.
    func today(_ sources: [Event.Source] = Event.Source.allCases, now: Date = Date(), calendar: Calendar = .current) -> [Double] {
        guard let latest else { return [] }
        let midnight = calendar.startOfDay(for: now).timeIntervalSince(latest.start) / 3600
        return Array(hours(sources).dropFirst(max(0, Int(midnight.rounded(.up)))))
    }
}

extension PanelModel {
    /// Asks AegisCore how many events it collected in each of the last 24 hours.
    func refreshActivity() async {
        if case let .activity(activity) = await service.handle(.activity(hours: CoreRequest.maxActivityHours)) {
            ActivityPresence.shared.latest = activity
        }
    }
}

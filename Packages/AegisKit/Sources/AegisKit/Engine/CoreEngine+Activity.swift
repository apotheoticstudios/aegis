import Foundation

extension CoreEngine {
    /// Events collected per hour, the last of them the current hour (#8): counts only, never content.
    func activity(hours requested: Int) async -> CoreResponse {
        let hours = min(max(requested, 1), CoreRequest.maxActivityHours)
        let now = clock()
        guard let current = calendar.dateInterval(of: .hour, for: now)?.start else {
            return .refused(code: "bad_request")
        }
        let start = current.addingTimeInterval(-Double(hours - 1) * 3600)
        do {
            // Store windows are half-open; the extra second keeps an event stamped exactly now.
            let events = try await allEvents(from: start, to: now.addingTimeInterval(1))
            return .activity(HourlyActivity.count(events, from: start, hours: hours))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }
}

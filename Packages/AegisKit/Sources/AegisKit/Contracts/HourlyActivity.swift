import Foundation

/// How many events Aegis collected in each hour, by source (#8, additive): counts only, never content, for the
/// panel's charts.
public struct HourlyActivity: Codable, Sendable, Hashable {
    /// The start of the first hour.
    public var start: Date
    /// For each source that had events, one count per hour, oldest first.
    public var counts: [Event.Source: [Int]]

    public init(start: Date, counts: [Event.Source: [Int]]) {
        self.start = start
        self.counts = counts
    }

    /// Counts `events` into `hours` hours from `start`; events outside them are left out.
    public static func count(_ events: [Event], from start: Date, hours: Int) -> HourlyActivity {
        var counts: [Event.Source: [Int]] = [:]
        for event in events {
            let offset = event.eventTime.timeIntervalSince(start)
            guard offset >= 0, offset < Double(hours) * 3600 else { continue }
            counts[event.source, default: Array(repeating: 0, count: hours)][Int(offset / 3600)] += 1
        }
        return HourlyActivity(start: start, counts: counts)
    }

    /// Every source's counts added together, hour by hour.
    public func total(hours: Int) -> [Int] {
        counts.values.reduce(Array(repeating: 0, count: hours)) { sum, list in
            zip(sum, list + Array(repeating: 0, count: max(0, hours - list.count))).map { $0 + $1 }
        }
    }
}

// Aegis skills (#285), for OpenJarvis-format skills. Changes: local calendar schedules for owner command recipes.

import Foundation

/// A wall-clock time on selected weekdays. Calendar weekday numbers run from Sunday (1) to Saturday (7).
public struct SkillSchedule: Codable, Sendable, Hashable, CustomStringConvertible {
    public let weekdays: Set<Int>
    public let hour: Int
    public let minute: Int

    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// Parses a canonical schedule, such as `weekdays 07:30` or `mon,wed,fri 06:45`.
    public init?(_ text: String) {
        let parts = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let days = Self.days(String(parts[0])) else { return nil }
        let clock = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2, (1 ... 2).contains(clock[0].count), clock[0].allSatisfy(\.isNumber), clock[1].count == 2,
              clock[1].allSatisfy(\.isNumber), let hour = Int(clock[0]), let minute = Int(clock[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        else { return nil }
        weekdays = days
        self.hour = hour
        self.minute = minute
    }

    /// Whether this is one of the selected weekdays; callers decide when to dispatch and avoid repeats.
    public func isDue(on date: Date, calendar: Calendar) -> Bool {
        weekdays.contains(calendar.component(.weekday, from: date))
    }

    /// The scheduled time on this day, or nil for an unselected day or a nonexistent daylight-saving time.
    public func time(on date: Date, calendar: Calendar) -> Date? {
        guard isDue(on: date, calendar: calendar),
              let time = calendar.date(
                  bySettingHour: hour,
                  minute: minute,
                  second: 0,
                  of: date,
                  matchingPolicy: .strict,
                  repeatedTimePolicy: .first,
                  direction: .forward
              ),
              calendar.isDate(time, inSameDayAs: date)
        else { return nil }
        return time
    }

    public var description: String {
        let days = switch weekdays {
        case Set(1 ... 7): "daily"
        case Set(2 ... 6): "weekdays"
        case Set([1, 7]): "weekends"
        default: weekdays.sorted().map { Self.dayNames[$0 - 1] }.joined(separator: ",")
        }
        return String(format: "%@ %02d:%02d", days, hour, minute)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let schedule = Self(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid skill schedule")
        }
        self = schedule
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func days(_ text: String) -> Set<Int>? {
        switch text {
        case "daily": return Set(1 ... 7)
        case "weekdays": return Set(2 ... 6)
        case "weekends": return [1, 7]
        default: break
        }
        let fullNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let tokens = text.split(separator: ",", omittingEmptySubsequences: false)
        var result: Set<Int> = []
        for token in tokens {
            let day = token.hasSuffix("s") ? String(token.dropLast()) : String(token)
            guard let index = dayNames.firstIndex(of: day) ?? fullNames.firstIndex(of: day) else { return nil }
            result.insert(index + 1)
        }
        return result.isEmpty ? nil : result
    }
}

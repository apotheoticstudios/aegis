import AegisKit
import Foundation

/// What the mapping needs from one calendar occurrence. `EKEvent` provides it in `EventKitSource`;
/// tests provide synthetic values.
public protocol CalendarOccurrenceValues {
    /// EventKit's `calendarItemIdentifier`: shared by every occurrence of a repeating item.
    var itemID: String { get }
    var calendarTitle: String? { get }
    var title: String? { get }
    var start: Date { get }
    var end: Date { get }
    var isAllDay: Bool { get }
    /// Nil for floating times (EventKit reports them in the Mac's current zone).
    var timeZone: TimeZone? { get }
    var location: String? { get }
    var status: CalendarOccurrence.Status { get }
    /// True for an occurrence of a repeating item, including one that was moved (detached).
    var isRepeating: Bool { get }
    /// EventKit's `occurrenceDate`: when this occurrence was originally scheduled.
    var originalDate: Date? { get }
    /// Who's invited (#184); nil when the event has no attendee list.
    var attendees: [CalendarAttendee]? { get }
    /// The location's coordinates when it was picked from Maps (#265); nil otherwise.
    var coordinate: CalendarOccurrence.Coordinate? { get }
}

public extension CalendarOccurrenceValues {
    var attendees: [CalendarAttendee]? {
        nil
    }

    var coordinate: CalendarOccurrence.Coordinate? {
        nil
    }
}

/// What the mapping needs from one reminder.
public protocol ReminderValues {
    var itemID: String { get }
    var listTitle: String? { get }
    var title: String? { get }
    /// EventKit's `dueDateComponents`: an hour means a timed due date; without one it's date-only.
    var due: DateComponents? { get }
    var isCompleted: Bool { get }
    var completedAt: Date? { get }
    var priority: Int { get }
}

/// Maps EventKit values to AegisKit's schedule contracts (v0.2). Times and states come straight from the
/// records, never from the model.
public enum ScheduleMapping {
    /// One occurrence. Its ID follows the item and the original occurrence date (#97), so moving one
    /// occurrence or a single event keeps its ID. Floating repeating dates are normalised so travel can't
    /// change them; `currentZone` is the zone EventKit used for them.
    public static func occurrence(
        _ values: some CalendarOccurrenceValues, currentZone: TimeZone, captureTime: Date
    ) -> CalendarOccurrence {
        var original: Date?
        if values.isRepeating {
            let date = values.originalDate ?? values.start
            original = values.timeZone == nil ? ScheduleID.floatingOccurrenceDate(date, in: currentZone) : date
        }
        return CalendarOccurrence(
            itemID: values.itemID,
            occurrenceDate: original,
            calendarTitle: values.calendarTitle,
            title: values.title ?? "",
            start: values.start,
            end: max(values.end, values.start),
            isAllDay: values.isAllDay,
            timeZone: values.timeZone?.identifier,
            location: values.location.flatMap { $0.isEmpty ? nil : $0 },
            status: values.status,
            captureTime: captureTime,
            attendees: values.attendees,
            coordinate: values.coordinate
        )
    }

    /// One reminder. A date-only due date becomes that day's start in its zone (or `currentZone`), with
    /// `hasTime` false; a timed one keeps its instant.
    public static func reminder(_ values: some ReminderValues, currentZone: TimeZone, captureTime: Date) -> ReminderItem {
        ReminderItem(
            itemID: values.itemID,
            listTitle: values.listTitle,
            title: values.title ?? "",
            due: values.due.flatMap { due($0, currentZone: currentZone) },
            isCompleted: values.isCompleted,
            completedAt: values.isCompleted ? values.completedAt : nil,
            priority: min(max(values.priority, 0), 9),
            captureTime: captureTime
        )
    }

    static func due(_ components: DateComponents, currentZone: TimeZone) -> ReminderItem.Due? {
        let zone = components.timeZone ?? currentZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hasTime = components.hour != nil
        var parts = DateComponents(year: components.year, month: components.month, day: components.day)
        if hasTime {
            parts.hour = components.hour
            parts.minute = components.minute ?? 0
        }
        guard parts.year != nil, parts.month != nil, parts.day != nil, let date = calendar.date(from: parts) else {
            return nil
        }
        return ReminderItem.Due(date: date, hasTime: hasTime, timeZone: zone.identifier)
    }
}

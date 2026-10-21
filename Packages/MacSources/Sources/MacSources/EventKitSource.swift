import AegisKit
import CoreLocation
import EventKit
import Foundation

/// Reads Calendar occurrences and Reminders for AegisCore (ADR-0013: the app's grants reach the agent).
/// It never asks for access itself; without full access it reports `permission_denied` and no checkpoint,
/// so the stored checkpoint stays and nothing is reconciled away. Never logs titles or notes.
public final class EventKitSource: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    /// Occurrences that overlap `window`. The scan is complete only when every calendar could be read.
    public func calendar(window: DateInterval, now: Date = Date(), zone: TimeZone = .current) -> CollectionBatch {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return CollectionBatch(source: .calendar, status: SourceStatus(ok: false, code: .permissionDenied), checkpoint: nil)
        }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        let occurrences = store.events(matching: predicate).map {
            ScheduleMapping.occurrence(EventValues(event: $0), currentZone: zone, captureTime: now)
        }
        return CollectionBatch(
            source: .calendar,
            status: SourceStatus(ok: true, code: occurrences.isEmpty ? .noData : .ok, count: occurrences.count),
            occurrences: occurrences,
            checkpoint: CollectionCheckpoint(
                source: .calendar, cursor: "window:\(ContractTime.format(window.start))", scannedAt: now, complete: true
            )
        )
    }

    /// Every incomplete reminder, plus those completed inside `window`.
    public func reminders(window: DateInterval, now: Date = Date(), zone: TimeZone = .current) async -> CollectionBatch {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return CollectionBatch(source: .reminders, status: SourceStatus(ok: false, code: .permissionDenied), checkpoint: nil)
        }
        let open = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        let done = await fetch(store.predicateForCompletedReminders(
            withCompletionDateStarting: window.start, ending: window.end, calendars: nil
        ))
        guard let open, let done else {
            return CollectionBatch(source: .reminders, status: SourceStatus(ok: false, code: .unreadable), checkpoint: nil)
        }
        var seen = Set<String>()
        let items = (open + done).filter { seen.insert($0.itemID).inserted }.map {
            ScheduleMapping.reminder($0, currentZone: zone, captureTime: now)
        }
        return CollectionBatch(
            source: .reminders,
            status: SourceStatus(ok: true, code: items.isEmpty ? .noData : .ok, count: items.count),
            reminders: items,
            checkpoint: CollectionCheckpoint(
                source: .reminders, cursor: "window:\(ContractTime.format(window.start))", scannedAt: now, complete: true
            )
        )
    }

    /// Copies what the mapping needs inside EventKit's callback, so no `EKReminder` crosses threads.
    private func fetch(_ predicate: NSPredicate) async -> [ReminderSnapshot]? {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.map(ReminderSnapshot.init))
            }
        }
    }
}

/// `EKEvent` as the mapping's values.
struct EventValues: CalendarOccurrenceValues {
    let event: EKEvent

    var itemID: String {
        event.calendarItemIdentifier
    }

    var calendarTitle: String? {
        event.calendar?.title
    }

    var title: String? {
        event.title
    }

    var start: Date {
        event.startDate
    }

    var end: Date {
        event.endDate
    }

    var isAllDay: Bool {
        event.isAllDay
    }

    var timeZone: TimeZone? {
        event.timeZone
    }

    var location: String? {
        event.location
    }

    /// EventKit's own coordinates for a location picked from Maps; nothing is looked up.
    var coordinate: CalendarOccurrence.Coordinate? {
        guard let point = event.structuredLocation?.geoLocation?.coordinate,
              (-90 ... 90).contains(point.latitude), (-180 ... 180).contains(point.longitude),
              point.latitude != 0 || point.longitude != 0
        else { return nil }
        return .init(latitude: point.latitude, longitude: point.longitude)
    }

    var status: CalendarOccurrence.Status {
        switch event.status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .cancelled
        default: .none
        }
    }

    var isRepeating: Bool {
        event.hasRecurrenceRules || event.isDetached
    }

    var originalDate: Date? {
        event.occurrenceDate
    }

    /// From the invitation's participants: name, `mailto:` address, and whether it's the owner (#184).
    var attendees: [CalendarAttendee]? {
        guard let participants = event.attendees, !participants.isEmpty else { return nil }
        return participants.map { participant in
            let address = participant.url.absoluteString
            let email = address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)).lowercased() : ""
            return CalendarAttendee(
                name: participant.name.flatMap { $0.isEmpty ? nil : $0 }, email: email.isEmpty ? nil : email,
                isOwner: participant.isCurrentUser
            )
        }
    }
}

/// A reminder's fields, copied out of EventKit's callback.
struct ReminderSnapshot: ReminderValues, Sendable {
    let itemID: String
    let listTitle: String?
    let title: String?
    let due: DateComponents?
    let isCompleted: Bool
    let completedAt: Date?
    let priority: Int

    init(_ reminder: EKReminder) {
        itemID = reminder.calendarItemIdentifier
        listTitle = reminder.calendar?.title
        title = reminder.title
        due = reminder.dueDateComponents
        isCompleted = reminder.isCompleted
        completedAt = reminder.completionDate
        priority = reminder.priority
    }
}

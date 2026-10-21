import AegisKit
import AegisStorage
import Foundation
import MacSources

/// Keeps the schedule in the store (step 2.11): Calendar occurrences from yesterday to two days ahead and
/// every open reminder, read through EventKit with the app's grant (#66). A complete scan reconciles, so a
/// deleted event or finished reminder goes away and a moved occurrence keeps its one row (#97). Without
/// access nothing is read and nothing stored is removed. Titles are never logged.
actor ScheduleRefresher {
    private let store: GRDBEventStore
    private let source = EventKitSource()

    init(store: GRDBEventStore) {
        self.store = store
    }

    func refresh(now: Date = Date()) async {
        let today = Calendar.current.startOfDay(for: now)
        let window = DateInterval(start: today.addingTimeInterval(-86400), end: today.addingTimeInterval(3 * 86400))
        let events = source.calendar(window: window, now: now)
        if events.status.ok, events.checkpoint?.complete == true {
            try? await store.ingest(events)
            try? await store.reconcileOccurrences(
                source: .calendar, window: window, seen: Set(events.occurrences.map(\.id))
            )
        }
        let reminders = await source.reminders(window: window, now: now)
        if reminders.status.ok, reminders.checkpoint?.complete == true {
            try? await store.ingest(reminders)
            try? await store.reconcileOpenReminders(
                source: .reminders, seen: Set(reminders.reminders.filter { !$0.isCompleted }.map(\.id))
            )
        }
    }
}

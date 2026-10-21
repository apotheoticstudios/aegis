@testable import AegisKit
import Foundation

enum DoneFixture {
    static let now = CommitmentFixture.date(10, hour: 18)
    static let contact = Event.ContactRef(id: "example-alex", name: "Example Alex")

    static func question(_ id: String = "question", at: Date = CommitmentFixture.date(10), body: String = "Can you confirm?") -> Event {
        var event = CommitmentFixture.event(id, body, at: at)
        event.direction = .incoming
        event.sender = "+61 400 000 001"
        event.senderHandle = event.sender
        event.senderContact = contact
        return event
    }

    static func reply(_ question: Event, body: String = "Yes", after: TimeInterval = 60, id: String = "reply") -> Event {
        var event = CommitmentFixture.reply(question, body, after: after)
        event.id = EventID.make(source: event.source, sourceRecordID: id)
        return event
    }

    static func reminder(_ id: String, completed: Bool = true, at: Date? = CommitmentFixture.date(10, hour: 12)) -> ReminderItem {
        ReminderItem(
            itemID: id, listTitle: "Example list", title: "Example task", due: nil, isCompleted: completed,
            completedAt: at, priority: 0, captureTime: now
        )
    }

    static func occurrence(
        _ id: String, start: Date = CommitmentFixture.date(10, hour: 9), end: Date = CommitmentFixture.date(10, hour: 10),
        status: CalendarOccurrence.Status = .confirmed, allDay: Bool = false
    ) -> CalendarOccurrence {
        CalendarOccurrence(
            itemID: id, occurrenceDate: nil, calendarTitle: "Example calendar", title: "Example meeting", start: start,
            end: end, isAllDay: allDay, timeZone: "Australia/Brisbane", location: nil, status: status, captureTime: now
        )
    }

    static func compute(
        _ events: [Event] = [], occurrences: [CalendarOccurrence] = [], reminders: [ReminderItem] = [], maxItems: Int = 20
    ) -> [DoneItem] {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DoneToday.compute(
            events: events, occurrences: occurrences, reminders: reminders, contacts: BriefLayout.contactIDs(byID),
            now: now, calendar: CommitmentFixture.calendar, maxItems: maxItems
        )
    }
}

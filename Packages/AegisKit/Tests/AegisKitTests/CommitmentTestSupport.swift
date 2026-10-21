@testable import AegisKit
import Foundation

enum CommitmentFixture {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .gmt
        return value
    }

    static func date(_ day: Int = 7, hour: Int = 10, minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))
            ?? .distantPast
    }

    static func event(_ id: String, _ body: String, at: Date = date(), source: Event.Source = .imessage) -> Event {
        Event(
            source: source, sourceRecordID: id, appID: nil, sender: "me", threadID: "thread:" + id,
            eventTime: at, eventTimeSource: .sent, captureTime: at, title: nil, body: body, content: .complete,
            observations: [.init(route: source == .email ? .mailStore : .chatDB, sourceRecordID: id, captureTime: at)],
            direction: .outgoing, recipients: ["+61 400 000 001"]
        )
    }

    static func compute(_ events: [Event], now: Date = date().addingTimeInterval(60), maxItems: Int = 100) -> [Commitment] {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Commitments.compute(
            events: events, contacts: BriefLayout.contactIDs(byID), now: now, calendar: calendar, maxItems: maxItems
        )
    }

    static func reply(_ promise: Event, _ body: String, after seconds: TimeInterval = 60, incoming: Bool = false) -> Event {
        var reply = event("reply", body, at: promise.eventTime.addingTimeInterval(seconds), source: promise.source)
        reply.threadID = promise.threadID
        reply.recipients = promise.recipients
        reply.direction = incoming ? .incoming : .outgoing
        reply.senderHandle = incoming ? promise.recipients.first : nil
        return reply
    }
}

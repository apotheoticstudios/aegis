import Foundation

/// Open promises in the owner's own outgoing messages and emails (#182). Rules only, never a model or action.
public enum Commitments {
    private struct Context {
        let contacts: [String: Event.ContactRef]
        let now: Date
        let calendar: Calendar
    }

    /// Promises made in the last seven days, overdue first, then due soonest, then undated newest first.
    /// `contacts` uses `BriefLayout.contactIDs` and its normalized handle keys for these same events.
    public static func compute(
        events: [Event], contacts: [String: Event.ContactRef], now: Date, calendar: Calendar, maxItems: Int
    ) -> [Commitment] {
        guard maxItems > 0 else { return [] }
        let context = Context(contacts: contacts, now: now, calendar: calendar)
        let start = now.addingTimeInterval(-7 * 86400)
        let recent = events.filter { $0.eventTime >= start && $0.eventTime <= now }
        let threads = Dictionary(grouping: recent.filter { CommitmentCompletion.thread($0) != nil }) {
            CommitmentCompletion.thread($0) ?? ""
        }
        let promises = recent.flatMap { event -> [Commitment] in
            guard event.direction == .outgoing, event.source != .notification else { return [] }
            let later = CommitmentCompletion.thread(event).flatMap { threads[$0] } ?? []
            return CommitmentText.sentences(event).compactMap { sentence in
                promise(sentence, event: event, later: later, context: context)
            }
        }
        return Array(promises.sorted(by: ordered).prefix(maxItems))
    }

    private static func promise(
        _ sentence: String, event: Event, later: [Event], context: Context
    ) -> Commitment? {
        guard let (promise, verb) = detectedPromise(sentence, event: event, contacts: context.contacts, calendar: context.calendar),
              context.now.timeIntervalSince(promise.due ?? event.eventTime) <= 3 * 86400,
              !later.contains(where: {
                  $0.eventTime > event.eventTime && CommitmentCompletion.completes($0, verb: verb, madeAt: event.eventTime)
              })
        else { return nil }
        return promise
    }

    /// Shared detection and recipient naming for open promises and today's fulfilments.
    static func detectedPromise(
        _ sentence: String, event: Event, contacts: [String: Event.ContactRef], calendar: Calendar
    ) -> (Commitment, CommitmentVerb)? {
        let due = CommitmentDue.resolve(sentence, madeAt: event.eventTime, calendar: calendar)
        guard let verb = CommitmentDetection.verb(in: sentence, due: due) else { return nil }
        let person = recipient(event, contacts: contacts)
        return (Commitment(
            personID: person?.id, person: person?.name ?? "someone", text: CommitmentText.excerpt(sentence),
            due: due, madeAt: event.eventTime, eventID: event.id
        ), verb)
    }

    private static func recipient(_ event: Event, contacts: [String: Event.ContactRef]) -> Brief.Person? {
        if let thread = event.threadID, thread.contains(";+;") {
            let name = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Brief.Person(id: "group:" + thread, name: name.isEmpty ? "Group chat" : name)
        }
        guard let handle = event.recipients.first, !handle.isEmpty else { return nil }
        if let contact = contacts[BriefLayout.handleKey(handle)] {
            return Brief.Person(id: "contact:" + contact.id, name: contact.name)
        }
        return Brief.Person(id: "handle:" + handle, name: handle)
    }

    private static func ordered(_ lhs: Commitment, _ rhs: Commitment) -> Bool {
        if lhs.due != rhs.due {
            return (lhs.due ?? .distantFuture) < (rhs.due ?? .distantFuture)
        }
        if lhs.madeAt != rhs.madeAt {
            return lhs.madeAt > rhs.madeAt
        }
        if lhs.eventID != rhs.eventID {
            return lhs.eventID < rhs.eventID
        }
        return lhs.text < rhs.text
    }
}

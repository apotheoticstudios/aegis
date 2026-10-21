import Foundation

/// Who is waiting on the owner (#165), from named, merged events. Deterministic; no model.
public enum PeopleWaiting {
    /// Open questions per person or group chat, longest waiting first.
    public static func compute(events: [Event], now: Date, maxPeople: Int) -> [PersonWaiting] {
        guard maxPeople > 0 else { return [] }
        let ordered = events.filter { $0.eventTime <= now }.sorted {
            $0.eventTime == $1.eventTime ? $0.id < $1.id : $0.eventTime > $1.eventTime
        }
        var contacts: [String: Event.ContactRef] = [:]
        var threadReplies: [String: Date] = [:]
        var handleReplies: [String: Date] = [:]
        for event in ordered {
            // Resolve overlapping labels in a stable order, using the brief's exact lookup keys.
            contacts.merge(BriefLayout.contactIDs([event.id: event])) { first, _ in first }
            guard SenderDisplay.isOutgoing(event), event.source != .notification else { continue }
            if let thread = event.threadID, !thread.isEmpty {
                threadReplies[thread] = max(threadReplies[thread] ?? event.eventTime, event.eventTime)
            }
            for handle in event.recipients where !handle.isEmpty {
                handleReplies[handle] = max(handleReplies[handle] ?? event.eventTime, event.eventTime)
            }
        }
        var people: [String: PersonWaiting] = [:]
        for event in ordered {
            guard !SenderDisplay.isOutgoing(event), BriefInputPolicy.asksOwner(event),
                  !BriefLayout.plantedOrder(event), !NoiseRules.isNoise(event)
            else { continue }
            let reply: Date? = if let thread = event.threadID, !thread.isEmpty {
                threadReplies[thread]
            } else {
                event.senderHandle.flatMap { handleReplies[$0] }
            }
            guard reply.map({ $0 > event.eventTime }) != true,
                  let person = BriefLayout.person(of: [event], contacts: contacts)
            else { continue }
            if var waiting = people[person.id] {
                waiting.waitingSince = event.eventTime
                waiting.questions += 1
                if waiting.eventIDs.count < 10 {
                    waiting.eventIDs.append(event.id)
                }
                people[person.id] = waiting
            } else {
                people[person.id] = PersonWaiting(
                    person: person, waitingSince: event.eventTime, questions: 1,
                    latest: excerpt(event.body), eventIDs: [event.id]
                )
            }
        }
        return Array(people.values.sorted {
            $0.waitingSince == $1.waitingSince ? $0.person.id < $1.person.id : $0.waitingSince < $1.waitingSince
        }.prefix(maxPeople))
    }

    private static func excerpt(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? Unicode.Scalar(UInt8(32)) : scalar
        }
        let line = String(String.UnicodeScalarView(scalars))
        guard scalars.count > 140 else { return line }
        return String(String.UnicodeScalarView(scalars.prefix(139))) + "…"
    }
}

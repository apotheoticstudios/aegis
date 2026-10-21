import Foundation

extension Commitments {
    /// Last week's promises and their first fulfilment, using exactly the open-promise detection rules.
    static func fulfilled(
        events: [Event], contacts: [String: Event.ContactRef], now: Date, calendar: Calendar
    ) -> [(promise: Commitment, completion: Event)] {
        let start = now.addingTimeInterval(-7 * 86400)
        let recent = events.filter { $0.eventTime >= start && $0.eventTime <= now }.sorted {
            ($0.eventTime, $0.id) < ($1.eventTime, $1.id)
        }
        let threads = Dictionary(grouping: recent.filter { CommitmentCompletion.thread($0) != nil }) {
            CommitmentCompletion.thread($0) ?? ""
        }
        return recent.flatMap { event -> [(promise: Commitment, completion: Event)] in
            guard event.direction == .outgoing, event.source != .notification else { return [] }
            let later = CommitmentCompletion.thread(event).flatMap { threads[$0] } ?? []
            return CommitmentText.sentences(event).compactMap { sentence in
                guard let (promise, verb) = detectedPromise(sentence, event: event, contacts: contacts, calendar: calendar),
                      let completion = later.first(where: {
                          $0.eventTime > event.eventTime && CommitmentCompletion.completes($0, verb: verb, madeAt: event.eventTime)
                      }) else { return nil }
                return (promise, completion)
            }
        }
    }
}

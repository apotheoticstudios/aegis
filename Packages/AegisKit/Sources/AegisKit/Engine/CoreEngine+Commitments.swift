import Foundation

struct CommitmentSnapshot: Sendable {
    let events: [Event]
    let contacts: [String: Event.ContactRef]
    let now: Date
    let calendar: Calendar
    let muted: Set<String>
}

extension CoreEngine {
    /// The last week's open promises, with the same naming, merging and visibility as `people()`.
    func commitments() async -> CoreResponse {
        do {
            let snapshot = try await commitmentSnapshot()
            let promises = Commitments.compute(
                events: snapshot.events, contacts: snapshot.contacts, now: snapshot.now,
                calendar: snapshot.calendar, maxItems: Int.max
            )
            // BriefLayout identifies incoming people; these outgoing promises identify their recipients.
            let visible = promises.filter { promise in
                promise.personID.map { !snapshot.muted.contains($0) } ?? true
            }
            return .commitments(Array(visible.prefix(12)))
        } catch {
            return .refused(code: "store_unavailable")
        }
    }
}

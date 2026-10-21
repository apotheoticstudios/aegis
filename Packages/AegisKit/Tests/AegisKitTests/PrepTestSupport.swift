@testable import AegisKit
import Foundation

let prepNow = Date(timeIntervalSince1970: 1_791_000_000)
let prepContacts = ContactIndex([
    ContactSnapshot(
        id: "example-alex",
        displayName: "Alex Example",
        phones: ["+61 400 000 101"],
        emails: ["alex@example.com", "alex.work@example.com"]
    ),
    ContactSnapshot(
        id: "example-other",
        displayName: "Other Example",
        phones: ["+61 400 000 102"],
        emails: ["other@example.com"]
    ),
])

func prepOccurrence(attendees: [CalendarAttendee]? = [
    CalendarAttendee(name: "Alex Example", email: "ALEX@EXAMPLE.COM", isOwner: false),
    CalendarAttendee(name: "Owner Example", email: "owner@example.com", isOwner: true),
]) -> CalendarOccurrence {
    CalendarOccurrence(
        itemID: "example-meeting", occurrenceDate: nil, calendarTitle: nil, title: "Example meeting",
        start: prepNow.addingTimeInterval(3600), end: prepNow.addingTimeInterval(7200), isAllDay: false,
        timeZone: nil, location: nil, status: .confirmed, captureTime: prepNow, attendees: attendees
    )
}

func prepEvent(
    _ id: String, age: TimeInterval = 60, handle: String = "alex@example.com", outgoing: Bool = false,
    source: Event.Source = .imessage, body: String = "Can you send the Example plan?"
) -> Event {
    Event(
        source: source, sourceRecordID: id, appID: nil, sender: outgoing ? "me" : handle, threadID: "example-thread",
        eventTime: prepNow.addingTimeInterval(-age), eventTimeSource: .sent, captureTime: prepNow,
        title: source == .email ? "Example plan" : nil, body: body, content: .complete, observations: [],
        senderHandle: outgoing ? "owner@example.com" : handle, recipients: outgoing ? [handle] : []
    )
}

func prepStore(_ events: [Event], occurrence: CalendarOccurrence = prepOccurrence()) async throws -> MemoryStore {
    let store = MemoryStore()
    var batch = CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil)
    batch.occurrences = [occurrence]
    try await store.ingest(batch)
    return store
}

struct PrepRules: OwnerRulesPersistence {
    let rules: OwnerRules
    func load() throws -> OwnerRules {
        rules
    }

    func save(_: OwnerRules) throws {}
}

/// Records only synthetic jobs in memory; never logs collected text.
final class PrepModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: ModelJob?
    let text: String?
    let status: ModelJobResult.Status
    let throwsError: Bool

    init(
        text: String? = "{\"answer\":\"Alex Example asked for the plan.\",\"event_ids\":[],\"schedule_ids\":[]}",
        status: ModelJobResult.Status = .completed, throwsError: Bool = false
    ) {
        self.text = text
        self.status = status
        self.throwsError = throwsError
    }

    var lastJob: ModelJob? {
        lock.withLock { recorded }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        lock.withLock { recorded = job }
        if throwsError {
            throw CocoaError(.fileReadUnknown)
        }
        return ModelJobResult(
            jobID: job.id, status: status, text: status == .completed ? text : nil,
            failure: status == .failed ? .internalError : nil
        )
    }

    func cancel(jobID _: String) async {}
}

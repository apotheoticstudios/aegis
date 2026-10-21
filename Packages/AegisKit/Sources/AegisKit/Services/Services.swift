import Foundation

/// Reads one source. Collectors only read: none of these protocols can change the owner's data.
public protocol EventCollector: Sendable {
    var source: SourceKind { get }
    /// Collects what changed after `checkpoint` (everything when nil), as of `now`.
    func collect(after checkpoint: CollectionCheckpoint?, now: Date) async throws -> CollectionBatch
}

/// A keyset cursor for event pages, ordered by event time then stable ID.
public struct EventCursor: Sendable, Equatable {
    public let time: Date
    public let id: String

    /// Continue after the last event returned by a page. Use an unchanged window while paging.
    public init(after event: Event) {
        time = event.eventTime
        id = event.id
    }
}

/// AegisCore's database. It's the only writer.
public protocol EventStore: Sendable {
    /// Stores a batch's records and its checkpoint in one transaction; replaying a batch changes nothing.
    func ingest(_ batch: CollectionBatch) async throws
    func checkpoint(for source: SourceKind) async throws -> CollectionCheckpoint?
    /// Events whose time falls in the window, oldest first. A store may return only its first page.
    func events(from start: Date, to end: Date) async throws -> [Event]
    /// One page of the window, ordered by event time then ID, after `cursor`; at most `limit` events.
    func events(from start: Date, to end: Date, after cursor: EventCursor?, limit: Int) async throws -> [Event]
    /// The stored events with these IDs, in no particular order; unknown IDs are left out.
    func events(ids: [String]) async throws -> [Event]
    /// Events in the window whose sender, title or body contain every word of `text` (#163). Words are
    /// literal text, never query syntax; newest first; at most `limit`.
    func search(_ text: String, from start: Date, to end: Date, limit: Int) async throws -> [Event]
    func occurrences(from start: Date, to end: Date) async throws -> [CalendarOccurrence]
    /// Reminders that are open, or that were completed in the window.
    func reminders(from start: Date, to end: Date) async throws -> [ReminderItem]
    /// Stores a complete brief; only a complete one replaces the last.
    func saveBrief(_ brief: StoredBrief) async throws
    func latestBrief() async throws -> StoredBrief?
}

/// The owner's contacts as an index for naming senders (AegisCore reads Contacts; tests use fakes).
/// Nil when Contacts can't be read: senders then show as their raw handles.
public protocol ContactsProvider: Sendable {
    func index() async -> ContactIndex?
}

/// Runs model jobs (ModelService, or a fake in tests).
public protocol ModelClient: Sendable {
    func run(_ job: ModelJob) async throws -> ModelJobResult
    func cancel(jobID: String) async
    /// The text a running job has written so far (#263), so a reply can be spoken while it's written; nil when
    /// the job isn't running.
    func partial(jobID: String) async -> String?
    /// Meaning vectors (L2-normalised) for each text, from the on-device embedding model (#309); nil when unavailable.
    func embed(_ texts: [String]) async -> [[Float]]?
}

public extension ModelClient {
    func partial(jobID _: String) async -> String? {
        nil
    }

    func embed(_: [String]) async -> [[Float]]? {
        nil
    }
}

/// AegisCore's service as the panel sees it.
public protocol CoreService: Sendable {
    func handle(_ request: CoreRequest) async -> CoreResponse
}

public extension EventStore {
    /// A plain scan for stores without a text index (tests); GRDBEventStore answers from FTS5.
    func search(_ text: String, from start: Date, to end: Date, limit: Int) async throws -> [Event] {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        let found = try await events(from: start, to: end).filter { event in
            let haystack = [event.sender, event.senderContact?.name, event.title, event.body]
                .compactMap(\.self).joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
        return Array(found.sorted { $0.eventTime > $1.eventTime }.prefix(limit))
    }
}

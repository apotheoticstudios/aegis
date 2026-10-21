import Foundation

/// A source Aegis collects from.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case notifications, messages, mail, calendar, reminders, contacts
}

/// Where a collector got to in a source, so the next scan can carry on (Stage 1, #64).
///
/// The cursor is opaque to everyone but the collector that wrote it (for example a row ID plus a
/// modification stamp). Records and checkpoint are stored together, so a crash never skips records.
public struct CollectionCheckpoint: Codable, Sendable, Hashable {
    public var source: SourceKind
    public var cursor: String
    public var scannedAt: Date
    /// Whether the scan covered the source's whole scope. An incomplete scan never means that records it
    /// didn't see were deleted; only a complete one may reconcile removals.
    public var complete: Bool

    public init(source: SourceKind, cursor: String, scannedAt: Date, complete: Bool) {
        self.source = source
        self.cursor = cursor
        self.scannedAt = scannedAt
        self.complete = complete
    }
}

/// How one source looked: whether it could be read, how much it gave, and when it last worked. Lets the
/// panel and the brief tell "nothing arrived" apart from "the source couldn't be read".
/// Contract change #186: status also carries `formatChanged` and `stale` (see `SourceStatus.Code`).
/// `lastSuccess` is the last committed successful scan, including empty scans, never an event time.
/// No checkpoint or CoreRequest changes are required; `.status` already carries this coverage.
public struct SourceCoverage: Codable, Sendable, Hashable {
    public var source: SourceKind
    public var status: SourceStatus.Code
    public var events: Int
    public var lastSuccess: Date?

    public init(source: SourceKind, status: SourceStatus.Code, events: Int, lastSuccess: Date?) {
        self.source = source
        self.status = status
        self.events = events
        self.lastSuccess = lastSuccess
    }

    /// True when the source was read, even if it had nothing new.
    public var readable: Bool {
        status == .ok || status == .noData
    }
}

/// The output of one collector run: records, problems, and the checkpoint to store with them.
public struct CollectionBatch: Sendable, Equatable {
    public var source: SourceKind
    public var status: SourceStatus
    public var events: [Event]
    public var occurrences: [CalendarOccurrence]
    public var reminders: [ReminderItem]
    public var problems: [ReadProblem]
    /// Nil when the scan failed; the stored checkpoint then stays as it was.
    public var checkpoint: CollectionCheckpoint?

    public init(
        source: SourceKind, status: SourceStatus, events: [Event] = [], occurrences: [CalendarOccurrence] = [],
        reminders: [ReminderItem] = [], problems: [ReadProblem] = [], checkpoint: CollectionCheckpoint?
    ) {
        self.source = source
        self.status = status
        self.events = events
        self.occurrences = occurrences
        self.reminders = reminders
        self.problems = problems
        self.checkpoint = checkpoint
    }
}

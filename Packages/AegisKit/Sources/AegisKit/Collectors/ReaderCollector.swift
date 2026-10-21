import Foundation

/// A AegisKit reader as an `EventCollector` (Stage 1 step 2.10).
///
/// Each scan reads what arrived since the last one, starting `overlap` earlier so records that arrive
/// late are not missed; storing a record twice changes nothing (stable event IDs, idempotent ingest).
/// The very first scan looks back `firstLookback`. A store that can't be read gives its status code and
/// no checkpoint, so the stored checkpoint stays and nothing is reconciled away. Collected text stays data.
public struct ReaderCollector: EventCollector {
    public typealias Read = @Sendable (_ path: URL, _ now: Date, _ since: Date?) throws -> ReadResult

    public let source: SourceKind
    public let overlap: TimeInterval
    public let firstLookback: TimeInterval
    private let path: URL
    private let read: Read

    public init(
        source: SourceKind, path: URL, overlap: TimeInterval = 6 * 3600, firstLookback: TimeInterval = 2 * 86400,
        read: @escaping Read
    ) {
        self.source = source
        self.path = path
        self.overlap = overlap
        self.firstLookback = firstLookback
        self.read = read
    }

    /// The Notification Center database (`db2/db`).
    public static func notifications(at path: URL) -> ReaderCollector {
        ReaderCollector(source: .notifications, path: path) { try NotificationReader.read($0, now: $1, since: $2) }
    }

    /// The Messages database (`chat.db`).
    public static func messages(at path: URL) -> ReaderCollector {
        ReaderCollector(source: .messages, path: path) { try MessagesReader.read($0, now: $1, since: $2) }
    }

    /// Apple Mail: the Mail folder, a version folder or an Envelope Index.
    public static func mail(at path: URL) -> ReaderCollector {
        ReaderCollector(source: .mail, path: path) { try MailReader.read($0, now: $1, since: $2) }
    }

    public func collect(after checkpoint: CollectionCheckpoint?, now: Date) async throws -> CollectionBatch {
        let since = checkpoint.flatMap(Self.scannedAt).map { $0.addingTimeInterval(-overlap) }
            ?? now.addingTimeInterval(-firstLookback)
        let result: ReadResult
        do {
            result = try read(path, now, since)
        } catch is UnknownSchemaError {
            return CollectionBatch(source: source, status: SourceStatus(ok: false, code: .formatChanged), checkpoint: nil)
        } catch let error as StoreUnavailable {
            return CollectionBatch(source: source, status: SourceStatus(ok: false, code: error.code), checkpoint: nil)
        }
        guard result.status.ok else {
            return CollectionBatch(source: source, status: result.status, problems: result.problems, checkpoint: nil)
        }
        return CollectionBatch(
            source: source,
            status: result.status,
            events: result.events,
            problems: result.problems,
            // Incremental: events are never reconciled away, so the scan is never "complete".
            checkpoint: CollectionCheckpoint(
                source: source, cursor: Self.cursorPrefix + ContractTime.format(now), scannedAt: now, complete: false
            )
        )
    }

    static let cursorPrefix = "scanned:"

    static func scannedAt(_ checkpoint: CollectionCheckpoint) -> Date? {
        guard checkpoint.cursor.hasPrefix(cursorPrefix) else {
            return nil
        }
        return ContractTime.parse(String(checkpoint.cursor.dropFirst(cursorPrefix.count)))
    }
}

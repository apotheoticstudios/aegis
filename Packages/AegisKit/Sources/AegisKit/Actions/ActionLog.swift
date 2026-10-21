import Foundation

/// Append-only audit storage. Retention may expire old generations; individual entries cannot be edited.
/// Implementations must serialize reads/appends and bound both returned entries and persisted generations.
public protocol ActionLogPersistence: Sendable {
    var maxEntries: Int { get }
    func load() throws -> [ActionLogEntry]
    func append(_ entry: ActionLogEntry) throws
}

/// Serialized audit access, with no payload-bearing API and no executor.
public actor ActionLog {
    private let persistence: any ActionLogPersistence

    public init(persistence: any ActionLogPersistence) {
        self.persistence = persistence
    }

    public func append(_ entry: ActionLogEntry) throws {
        try persistence.append(entry)
    }

    /// The newest bounded entries, in append order (not sorted by caller-supplied timestamps).
    public func entries() throws -> [ActionLogEntry] {
        try persistence.load()
    }
}

/// Stable failure codes; filesystem errors and corrupt record text are never exposed as log content.
public enum ActionLogError: Error, Sendable, Equatable {
    case invalidLimit, invalidLocation, persistenceFailure, corruptLog
}

/// Local JSON-lines storage, with atomic replacement for every logical append.
/// At N entries, the completed generation becomes `.1` and the next append starts a new active file.
/// Only one archive is retained: disk holds at most 2N entries, and load returns the newest N.
/// Use one instance per file in one process; cross-process writers are intentionally unsupported.
public final class ActionLogFile: ActionLogPersistence {
    public let url: URL
    public let maxEntries: Int
    public var archiveURL: URL {
        url.appendingPathExtension("1")
    }

    private let lock = NSLock()
    /// Fixed-size metadata and closed codes make each line small; also reject oversized/corrupt files on read.
    private static let maxLineBytes = 4096

    public init(url: URL, maxEntries: Int = 1000) throws {
        guard maxEntries > 0, maxEntries <= Int.max / Self.maxLineBytes else { throw ActionLogError.invalidLimit }
        guard url.isFileURL else { throw ActionLogError.invalidLocation }
        self.url = url
        self.maxEntries = maxEntries
    }

    public func load() throws -> [ActionLogEntry] {
        try lock.withLock {
            let active = try read(url)
            let archived = try read(archiveURL)
            // Recovery after interruption between archive replacement and active replacement: same generation.
            let combined = active == archived ? active : archived + active
            return Array(combined.suffix(maxEntries))
        }
    }

    public func append(_ entry: ActionLogEntry) throws {
        try lock.withLock {
            var active = try read(url)
            if active.count == maxEntries {
                try write(active, to: archiveURL)
                active = []
            }
            active.append(entry)
            try write(active, to: url)
        }
    }

    private func read(_ location: URL) throws -> [ActionLogEntry] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value <= Int64(maxEntries * Self.maxLineBytes)
            else { throw ActionLogError.corruptLog }
            let data = try Data(contentsOf: location)
            guard data.isEmpty || data.last == 10 else { throw ActionLogError.corruptLog }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
            guard lines.count <= maxEntries else { throw ActionLogError.corruptLog }
            return try lines.map { line in
                guard !line.isEmpty, line.count <= Self.maxLineBytes else { throw ActionLogError.corruptLog }
                return try JSONDecoder().decode(ActionLogEntry.self, from: Data(line))
            }
        } catch let error as ActionLogError {
            throw error
        } catch is DecodingError {
            throw ActionLogError.corruptLog
        } catch {
            throw ActionLogError.persistenceFailure
        }
    }

    private func write(_ entries: [ActionLogEntry], to location: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = Data()
            for entry in entries {
                let line = try encoder.encode(entry)
                guard line.count < Self.maxLineBytes else { throw ActionLogError.corruptLog }
                data.append(line)
                data.append(10)
            }
            try data.write(to: location, options: .atomic)
        } catch let error as ActionLogError {
            throw error
        } catch {
            throw ActionLogError.persistenceFailure
        }
    }
}

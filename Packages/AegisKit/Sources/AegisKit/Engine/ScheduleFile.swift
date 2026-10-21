import Foundation

/// Keeps the brief scheduler's state between launches. The engine saves it before starting any work.
public protocol SchedulePersistence: Sendable {
    func load() throws -> BriefSchedule?
    func save(_ schedule: BriefSchedule) throws
}

/// The schedule as a small JSON file beside AegisCore's database, replaced atomically.
public struct ScheduleFile: SchedulePersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> BriefSchedule? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try IPCCoding.decode(BriefSchedule.self, from: Data(contentsOf: url))
    }

    public func save(_ schedule: BriefSchedule) throws {
        try IPCCoding.encode(schedule).write(to: url, options: .atomic)
    }
}

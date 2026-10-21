import Foundation

/// The morning routine's saved state (#286): today's proposals, the owner's remembered decisions, and jobs already
/// answered so they aren't offered again.
public struct RoutineState: Codable, Sendable, Hashable {
    public var approvals: Approvals
    public var today: MorningRoutine?
    /// Proposal IDs the owner answered, with when; kept 30 days.
    public var handled: [String: Date]

    public static let empty = RoutineState(approvals: .empty, today: nil, handled: [:])

    public init(approvals: Approvals, today: MorningRoutine?, handled: [String: Date]) {
        self.approvals = approvals
        self.today = today
        self.handled = handled
    }
}

/// Where the morning routine is kept.
public protocol RoutinePersistence: Sendable {
    func load() throws -> RoutineState
    func save(_ state: RoutineState) throws
}

/// The routine as JSON in Aegis's private folder, written atomically.
public struct RoutineFile: RoutinePersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> RoutineState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(RoutineState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: RoutineState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

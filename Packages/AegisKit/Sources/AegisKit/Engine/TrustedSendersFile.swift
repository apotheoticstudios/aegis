import Foundation

/// Where the owner's "Not junk" senders are kept (#167).
public protocol TrustedSendersPersistence: Sendable {
    func load() throws -> Set<String>
    func save(_ senders: Set<String>) throws
}

/// The trusted senders as a JSON list in Aegis's private folder; written atomically.
public struct TrustedSendersFile: TrustedSendersPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Set(JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    public func save(_ senders: Set<String>) throws {
        try JSONEncoder().encode(senders.sorted()).write(to: url, options: .atomic)
    }
}

import Foundation

/// Where Aegis's memory is kept (#222).
public protocol MemoryPersistence: Sendable {
    func load() throws -> MemoryBook
    func save(_ book: MemoryBook) throws
}

/// Memory as JSON in Aegis's private folder, written atomically; no file means nothing remembered yet.
public struct MemoryFile: MemoryPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> MemoryBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(MemoryBook.self, from: Data(contentsOf: url))
    }

    public func save(_ book: MemoryBook) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}

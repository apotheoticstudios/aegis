import Foundation

/// Where the owner's visibility and priority rules are kept (#185, additive).
public protocol OwnerRulesPersistence: Sendable {
    func load() throws -> OwnerRules
    func save(_ rules: OwnerRules) throws
}

/// Owner rules as JSON in Aegis's private folder, written atomically.
/// If no rules file exists, the optional legacy trusted-senders array supplies the trusted rules.
public struct OwnerRulesFile: OwnerRulesPersistence {
    public let url: URL
    public let legacyTrusted: URL?

    public init(url: URL, legacyTrusted: URL? = nil) {
        self.url = url
        self.legacyTrusted = legacyTrusted
    }

    public func load() throws -> OwnerRules {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(OwnerRules.self, from: Data(contentsOf: url))
        }
        if let legacyTrusted {
            return try OwnerRules(trusted: TrustedSendersFile(url: legacyTrusted).load())
        }
        return .empty
    }

    public func save(_ rules: OwnerRules) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(rules).write(to: url, options: .atomic)
    }
}

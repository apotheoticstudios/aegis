// Aegis skills (#285), for OpenJarvis-format skills. Changes: bounded in-memory owner recipe collection.

import Foundation

/// A bounded value collection of owner recipes. It performs no actions and does not persist owner text.
public struct SkillBook: Sendable {
    /// Limits are checked before replacing a recipe, so a failed add leaves the collection unchanged.
    public enum LimitError: Error, Equatable, Sendable {
        case tooManySkills
        case tooManySteps
        case commandTooLong
    }

    private var entries: [String: SkillManifest] = [:]

    public init() {}

    public var skills: [SkillManifest] {
        entries.values.sorted { $0.name < $1.name }
    }

    public mutating func add(_ manifest: SkillManifest) throws {
        guard manifest.steps.count <= 12 else { throw LimitError.tooManySteps }
        guard manifest.steps.allSatisfy({ $0.command.count <= 300 }) else { throw LimitError.commandTooLong }
        guard entries[manifest.name] != nil || entries.count < 50 else { throw LimitError.tooManySkills }
        entries[manifest.name] = manifest
    }

    @discardableResult
    public mutating func remove(name: String) -> SkillManifest? {
        guard let slug = SkillName.slug(name) else { return nil }
        return entries.removeValue(forKey: slug)
    }

    public func skill(named name: String) -> SkillManifest? {
        guard let slug = SkillName.slug(name) else { return nil }
        return entries[slug]
    }

    /// Matches an entire normalised owner phrase; never scans collected content for triggers.
    public func skill(forTrigger phrase: String) -> SkillManifest? {
        let phrase = Self.normalised(phrase)
        guard !phrase.isEmpty else { return nil }
        return skills.first { $0.trigger.map(Self.normalised) == phrase }
    }

    /// Recipes selected for this weekday. Callers use schedule.time and keep dispatch state to avoid repeats.
    public func due(on date: Date, calendar: Calendar) -> [SkillManifest] {
        skills.filter { $0.schedule?.isDue(on: date, calendar: calendar) == true }
    }

    private static func normalised(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/skills/types.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis; owner command recipes, no
// signing.

import Foundation

/// One owner command. Legacy OpenJarvis fields are inert compatibility data, never executable tools.
public struct SkillStep: Codable, Sendable, Hashable {
    public var command: String
    public var toolName: String
    public var skillName: String
    public var argumentsTemplate: String
    public var outputKey: String

    public init(
        command: String = "",
        toolName: String = "",
        skillName: String = "",
        argumentsTemplate: String = "{}",
        outputKey: String = ""
    ) {
        self.command = command
        self.toolName = toolName
        self.skillName = skillName
        self.argumentsTemplate = argumentsTemplate
        self.outputKey = outputKey
    }
}

/// A saved recipe of the owner's own commands, with OpenJarvis-format descriptive metadata.
public struct SkillManifest: Codable, Sendable, Hashable {
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    public var steps: [SkillStep]
    public var requiredCapabilities: [String]
    public var metadata: [String: SkillValue]
    public var tags: [String]
    public var depends: [String]
    public var userInvocable: Bool
    public var disableModelInvocation: Bool
    public var markdownContent: String

    public init(
        name: String, version: String = "0.1.0", description: String = "", author: String = "", steps: [SkillStep] = [],
        requiredCapabilities: [String] = [], metadata: [String: SkillValue] = [:], tags: [String] = [], depends: [String] = [],
        userInvocable: Bool = true, disableModelInvocation: Bool = false, markdownContent: String = ""
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.steps = steps
        self.requiredCapabilities = requiredCapabilities
        self.metadata = metadata
        self.tags = tags
        self.depends = depends
        self.userInvocable = userInvocable
        self.disableModelInvocation = disableModelInvocation
        self.markdownContent = markdownContent
    }

    /// The optional exact phrase chosen by the owner.
    public var trigger: String? {
        metadata["aegis"]?.map?["trigger"]?.string
    }

    /// The optional local calendar schedule chosen by the owner.
    public var schedule: SkillSchedule? {
        metadata["aegis"]?.map?["schedule"]?.string.flatMap(SkillSchedule.init)
    }
}

/// A small, untagged Codable value for frontmatter, without arbitrary objects or executable content.
public enum SkillValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([SkillValue])
    case map([String: SkillValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SkillValue].self) {
            self = .list(value)
        } else {
            self = try .map(container.decode([String: SkillValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .list(value): try container.encode(value)
        case let .map(value): try container.encode(value)
        }
    }

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var map: [String: SkillValue]? {
        guard case let .map(value) = self else { return nil }
        return value
    }

    var strings: [String]? {
        guard case let .list(value) = self else { return nil }
        let strings = value.compactMap(\.string)
        return strings.count == value.count ? strings : nil
    }

    var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var pythonType: String {
        switch self {
        case .string: "<class 'str'>"
        case let .number(value): value.rounded() == value ? "<class 'int'>" : "<class 'float'>"
        case .bool: "<class 'bool'>"
        case .list: "<class 'list'>"
        case .map: "<class 'dict'>"
        }
    }
}

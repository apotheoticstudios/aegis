// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/skills/parser.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis; typed values, no logging.

import Foundation

/// A frontmatter validation failure, retaining the upstream diagnostic text.
public enum SkillParseError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(message): message
        }
    }

    public var errorDescription: String? {
        description
    }
}

/// OpenJarvis's strict validation followed by tolerant field mapping. Does not log owner text.
public enum SkillParser {
    public static let maxNameLength = 64
    public static let maxDescriptionLength = 1024
    public static let maxCompatibilityLength = 500

    private static let specFields: Set<String> = ["name", "description", "license", "compatibility", "metadata", "allowed-tools"]
    private static let fieldMapping: [String: String] = [
        "version": "field", "author": "field", "tags": "field", "depends": "field", "required_capabilities": "field",
        "user_invocable": "field", "disable_model_invocation": "field", "platforms": "openjarvis_meta", "prerequisites": "openjarvis_meta",
    ]

    /// Parses already decoded frontmatter; explicit metadata.openjarvis fields take precedence.
    public static func parseFrontmatter(_ fields: [String: SkillValue], markdownContent: String = "") throws -> SkillManifest {
        try validateStrict(fields)
        var manifest = SkillManifest(
            name: fields["name"]?.string ?? "",
            description: fields["description"]?.string ?? "",
            markdownContent: markdownContent
        )
        let rawMetadata = fields["metadata"]?.map ?? [:]
        var openjarvis = rawMetadata["openjarvis"]?.map ?? [:]
        var unmapped: [String: SkillValue] = [:]
        for (key, value) in fields where !specFields.contains(key) {
            switch fieldMapping[key] {
            case "field": apply(key, value, to: &manifest)
            case "openjarvis_meta": openjarvis[key] = value
            default: unmapped[key] = value
            }
        }
        for (key, value) in openjarvis where fieldMapping[key] == "field" {
            apply(key, value, to: &manifest)
        }
        if !unmapped.isEmpty {
            openjarvis["original_frontmatter"] = .map(unmapped)
        }
        manifest.metadata = rawMetadata
        if !openjarvis.isEmpty {
            manifest.metadata["openjarvis"] = .map(openjarvis)
        }
        return manifest
    }

    private static func validateStrict(_ fields: [String: SkillValue]) throws {
        // Preserve upstream validation order, including checking both required keys before types.
        for key in ["name", "description"] where fields[key] == nil {
            throw SkillParseError.invalid("Missing required field in frontmatter: \(key)")
        }
        for key in ["name", "description"] {
            if let value = fields[key], value.string == nil {
                throw SkillParseError.invalid("Field '\(key)' must be a string, got \(value.pythonType)")
            }
        }
        let name = fields["name"]?.string ?? ""
        let description = fields["description"]?.string ?? ""
        try validateLength(name, field: "name", limit: maxNameLength)
        try validateLength(description, field: "description", limit: maxDescriptionLength)
        try validateName(name)
        if let compatibility = fields["compatibility"] {
            guard let text = compatibility.string else {
                throw SkillParseError.invalid("Field 'compatibility' must be a string")
            }
            if text.unicodeScalars.count > maxCompatibilityLength {
                throw SkillParseError.invalid("Field 'compatibility' exceeds 500 chars")
            }
        }
    }

    private static func validateLength(_ text: String, field: String, limit: Int) throws {
        let count = text.unicodeScalars.count
        guard count > 0, count <= limit else {
            throw SkillParseError.invalid("Field '\(field)' must be 1-\(limit) chars, got \(count)")
        }
    }

    static func validateName(_ name: String) throws {
        if name != name.lowercased() {
            throw SkillParseError.invalid("Skill name '\(name)' must be lowercase")
        }
        if name.hasPrefix("-") || name.hasSuffix("-") {
            throw SkillParseError.invalid("Skill name '\(name)' must not start or end with a hyphen")
        }
        if name.contains("--") {
            throw SkillParseError.invalid("Skill name '\(name)' must not contain consecutive hyphens")
        }
        for scalar in name.unicodeScalars where scalar != "-" && !isAlphanumeric(scalar) {
            throw SkillParseError.invalid(
                "Skill name '\(name)' contains invalid character '\(scalar)'; only lowercase alphanumeric and hyphens are allowed"
            )
        }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        // Match Python str.isalnum, including Unicode numbers but excluding combining marks.
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    private static func apply(_ key: String, _ value: SkillValue, to manifest: inout SkillManifest) {
        // Python permits arbitrary values here; Swift retains well-typed values and ignores incompatible mappings.
        switch key {
        case "version": manifest.version = value.string ?? manifest.version
        case "author": manifest.author = value.string ?? manifest.author
        case "tags": manifest.tags = value.strings ?? manifest.tags
        case "depends": manifest.depends = value.strings ?? manifest.depends
        case "required_capabilities": manifest.requiredCapabilities = value.strings ?? manifest.requiredCapabilities
        case "user_invocable": manifest.userInvocable = value.bool ?? manifest.userInvocable
        case "disable_model_invocation": manifest.disableModelInvocation = value.bool ?? manifest.disableModelInvocation
        default: break
        }
    }
}

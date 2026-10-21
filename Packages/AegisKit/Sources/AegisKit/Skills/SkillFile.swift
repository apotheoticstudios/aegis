// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/skills/loader.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis; strict markdown recipes,
// no TOML or logs.

import Foundation

/// Reads and writes local SKILL.md recipes. It never executes steps or follows source sidecars.
public enum SkillFile {
    /// Parses frontmatter and the first Steps list, rejecting invalid manifests rather than using the legacy fallback.
    public static func parse(_ text: String) throws -> SkillManifest {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw SkillParseError.invalid("Missing YAML frontmatter delimiters")
        }
        var fields = try SkillFrontmatter.parse(lines[1 ..< end].joined(separator: "\n"))
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        // A reserved writer extension preserves exact notes and inert legacy step fields across round trips.
        let candidate = fields["aegis_recipe"]?.map
        let recipe = candidate?["format"] == .number(1) ? candidate : nil
        if recipe != nil {
            fields.removeValue(forKey: "aegis_recipe")
        }
        var manifest = try SkillParser.parseFrontmatter(fields, markdownContent: body)
        manifest.steps = commands(in: body).map { SkillStep(command: $0) }
        if let recipe {
            guard recipe["format"] == .number(1), let markdown = recipe["markdown"]?.string,
                  let stepsValue = recipe["steps"], let data = try? JSONEncoder().encode(stepsValue),
                  let steps = try? JSONDecoder().decode([SkillStep].self, from: data)
            else { throw SkillParseError.invalid("Invalid Aegis recipe extension") }
            // The visible list remains authoritative when an owner edits a rendered file.
            if body == renderedBody(markdown: markdown, steps: steps) {
                let metadata = manifest.metadata
                fields.removeValue(forKey: "metadata")
                manifest = try SkillParser.parseFrontmatter(fields, markdownContent: markdown)
                manifest.metadata = metadata
                manifest.steps = steps
            }
        }
        return manifest
    }

    /// Writes readable command steps plus a lossless extension for exact notes and compatibility data.
    /// Manifests must have a spec-valid name and nonempty description, as with the upstream parser.
    public static func render(_ manifest: SkillManifest) -> String {
        var fields: [(String, SkillValue)] = [
            ("name", .string(manifest.name)), ("description", .string(manifest.description)),
            ("version", .string(manifest.version)), ("author", .string(manifest.author)),
            ("tags", .list(manifest.tags.map(SkillValue.string))), ("depends", .list(manifest.depends.map(SkillValue.string))),
            ("required_capabilities", .list(manifest.requiredCapabilities.map(SkillValue.string))),
            ("user_invocable", .bool(manifest.userInvocable)), ("disable_model_invocation", .bool(manifest.disableModelInvocation)),
            ("metadata", .map(manifest.metadata)),
        ]
        let stepValue = (try? JSONEncoder().encode(manifest.steps)).flatMap { try? JSONDecoder().decode(SkillValue.self, from: $0) }
        fields.append(("aegis_recipe", .map([
            "format": .number(1), "markdown": .string(manifest.markdownContent), "steps": stepValue ?? .list([]),
        ])))
        let header = fields.flatMap { renderField($0.0, value: $0.1) }.joined(separator: "\n")
        return "---\n\(header)\n---\n\(renderedBody(markdown: manifest.markdownContent, steps: manifest.steps))"
    }

    /// Discovers only immediate child directories containing SKILL.md; unreadable or invalid recipes are skipped silently.
    public static func discover(in directory: URL) -> [SkillManifest] {
        guard directory.isFileURL,
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let text = try? String(contentsOf: child.appendingPathComponent("SKILL.md"), encoding: .utf8)
            else { return nil }
            return try? parse(text)
        }.sorted { $0.name < $1.name }
    }

    private static func encoded(_ value: SkillValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private static func renderField(_ key: String, value: SkillValue, indent: String = "") -> [String] {
        let key = key.range(of: #"^[a-zA-Z_][a-zA-Z0-9_-]*$"#, options: .regularExpression) != nil ? key : encoded(.string(key))
        guard case let .map(fields) = value, !fields.isEmpty else { return ["\(indent)\(key): \(encoded(value))"] }
        return ["\(indent)\(key):"] + fields.keys.sorted().flatMap { name in
            renderField(name, value: fields[name] ?? .string(""), indent: indent + "  ")
        }
    }

    private static func renderedBody(markdown: String, steps: [SkillStep]) -> String {
        let list = steps.enumerated().map { "\($0.offset + 1). \($0.element.command)" }.joined(separator: "\n")
        // Reuse a matching body instead of duplicating its command list.
        if !markdown.isEmpty, commands(in: markdown) == steps.map(\.command) {
            return markdown
        }
        let section = "## Steps\n\(list)\n"
        if markdown.range(of: #"(?im)^\s*## steps\s*$"#, options: .regularExpression) != nil {
            return section + "\n## Notes\n" + markdown
        }
        return markdown.isEmpty ? section : markdown + "\n\n" + section
    }

    private static func commands(in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        let heading = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## steps" }
        var commands: [String] = []
        for raw in lines.dropFirst(heading.map { $0 + 1 } ?? 0) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#"), heading != nil {
                break
            }
            if let command = SkillCommand.capture(#"^(?:\d+[.)]|-)\s+(.+)$"#, line)?.first {
                commands.append(command)
            } else if !commands.isEmpty, !line.isEmpty {
                break
            }
        }
        return commands
    }
}

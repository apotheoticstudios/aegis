// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/skills/loader.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis; dependency-free YAML
// subset.

import Foundation

/// The deliberately small, non-executing YAML subset needed by recipe frontmatter.
enum SkillFrontmatter {
    struct Line {
        let indent: Int
        let text: String
    }

    static func parse(_ text: String) throws -> [String: SkillValue] {
        let lines = try text.components(separatedBy: "\n").compactMap { raw -> Line? in
            guard !raw.contains("\t") else { throw invalid }
            let stripped = try segments(raw, separator: "#", comment: true).first ?? ""
            let content = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return Line(indent: stripped.prefix(while: { $0 == " " }).count, text: content)
        }
        guard let first = lines.first else { return [:] }
        guard first.indent == 0 else { throw invalid }
        var cursor = 0
        let value = try block(lines, cursor: &cursor, indent: 0)
        guard cursor == lines.count, let map = value.map else { throw invalid }
        return map
    }

    private static var invalid: SkillParseError {
        .invalid("Invalid YAML frontmatter")
    }

    private static func block(_ lines: [Line], cursor: inout Int, indent: Int) throws -> SkillValue {
        if lines[cursor].text.hasPrefix("- ") {
            return try list(lines, cursor: &cursor, indent: indent)
        }
        var fields: [String: SkillValue] = [:]
        while cursor < lines.count, lines[cursor].indent == indent {
            let pieces = try segments(lines[cursor].text, separator: ":")
            guard pieces.count >= 2 else { throw invalid }
            let keyText = pieces[0].trimmingCharacters(in: .whitespaces)
            guard let key = try scalar(keyText).string, !key.isEmpty, fields[key] == nil else { throw invalid }
            let tail = pieces.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            cursor += 1
            if tail.isEmpty, cursor < lines.count, lines[cursor].indent > indent {
                fields[key] = try block(lines, cursor: &cursor, indent: lines[cursor].indent)
            } else {
                fields[key] = tail.isEmpty ? .map([:]) : try scalar(tail)
            }
        }
        return .map(fields)
    }

    private static func list(_ lines: [Line], cursor: inout Int, indent: Int) throws -> SkillValue {
        var values: [SkillValue] = []
        while cursor < lines.count, lines[cursor].indent == indent {
            guard lines[cursor].text.hasPrefix("- ") else { throw invalid }
            try values.append(scalar(String(lines[cursor].text.dropFirst(2))))
            cursor += 1
        }
        return .list(values)
    }

    private static func scalar(_ raw: String) throws -> SkillValue {
        let text = raw.trimmingCharacters(in: .whitespaces)
        // JSON is also YAML: rendering uses it for lossless strings, maps and nested lists.
        if let decoded = try? JSONDecoder().decode(SkillValue.self, from: Data(text.utf8)) {
            return decoded
        }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw invalid }
            let inside = String(text.dropFirst().dropLast())
            if inside.trimmingCharacters(in: .whitespaces).isEmpty {
                return .list([])
            }
            return try .list(segments(inside, separator: ",").map { try scalar($0) })
        }
        if text.hasPrefix("'") {
            guard text.count >= 2, text.hasSuffix("'") else { throw invalid }
            return .string(String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        if text.hasPrefix("\"") || text.hasPrefix("{") {
            throw invalid
        }
        if text.lowercased() == "true" {
            return .bool(true)
        }
        if text.lowercased() == "false" {
            return .bool(false)
        }
        if let number = Double(text), number.isFinite {
            return .number(number)
        }
        return .string(text)
    }

    /// Splits outside quotes and inline containers. A comment begins only after whitespace or at the start.
    private static func segments(_ text: String, separator: Character, comment: Bool = false) throws -> [String] {
        var state = ScanState()
        var pieces: [String] = []
        var current = ""
        let characters = Array(text)
        var skipEscapedQuote = false
        for (index, character) in characters.enumerated() {
            if skipEscapedQuote {
                skipEscapedQuote = false; continue
            }
            if state.quote == "'", character == "'", index + 1 < characters.count, characters[index + 1] == "'" {
                current += "''"
                skipEscapedQuote = true
                continue
            }
            if state.quote == nil, state.depth == 0, character == separator {
                if !comment || current.isEmpty || current.last?.isWhitespace == true {
                    pieces.append(current)
                    if comment {
                        return pieces
                    }
                    current = ""
                    continue
                }
            }
            state.consume(character)
            current.append(character)
        }
        guard state.quote == nil, state.depth == 0 else { throw invalid }
        pieces.append(current)
        return pieces
    }

    private struct ScanState {
        var quote: Character?
        var escaped = false
        var depth = 0
        var previous: Character?

        mutating func consume(_ character: Character) {
            defer { previous = character }
            if escaped {
                escaped = false; return
            }
            if quote == "\"", character == "\\" {
                escaped = true; return
            }
            if let quote {
                if character == quote {
                    self.quote = nil
                }
            } else if beginsQuote(character) {
                // Apostrophes in plain owner phrases are ordinary characters.
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            }
        }

        private func beginsQuote(_ character: Character) -> Bool {
            (character == "\"" || character == "'") &&
                (previous == nil || previous?.isWhitespace == true || [":", "[", ",", "{"].contains(previous))
        }
    }
}

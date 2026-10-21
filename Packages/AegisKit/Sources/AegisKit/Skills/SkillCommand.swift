// Aegis skills (#285), for OpenJarvis-format skills. Changes: explicit owner-only recipe command grammar, no actions.

import Foundation

/// A request about saved recipes, parsed exclusively from the owner's own words, never collected content.
/// Parsing describes intent only: execution must send each owner command through the normal confirmation pipeline.
public enum SkillCommand: Sendable, Equatable {
    case run(name: String)
    case create(name: String, steps: [String])
    case saveRecent(name: String, count: Int)
    case list
    case delete(name: String)
    case schedule(name: String, SkillSchedule)
    case show(name: String)

    public static func parse(_ text: String) -> SkillCommand? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[?!.]+$"#, with: "", options: .regularExpression)
        guard !line.contains("\n"), !line.contains("\r") else { return nil }
        if capture(#"^(?:what skills do i have|list my skills|show my skills)$"#, line) != nil {
            return .list
        }
        if capture(#"^run (?:my|the) .+ skill (?:daily|every .+) at .+$"#, line) != nil {
            return scheduled(line)
        }
        return creation(line) ?? recent(line) ?? named(line)
    }

    private static func creation(_ line: String) -> SkillCommand? {
        guard let parts = capture(#"^(?:create|make) a skill (?:called|named) (.+?)(?::\s*| that does\s+)(.+)$"#, line),
              let name = SkillName.slug(parts[0]) else { return nil }
        let separator = #"\s*(?:,\s*and\s+then\s+|,\s*then\s+|;\s*then\s+|;|\s+then\s+|,)\s*"#
        let steps = parts[1].replacingOccurrences(of: separator, with: "\n", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !steps.isEmpty, steps.allSatisfy({ !$0.isEmpty }) else { return nil }
        return .create(name: name, steps: steps)
    }

    private static func recent(_ line: String) -> SkillCommand? {
        if let parts = capture(#"^save that as a skill (?:called|named) (.+)$"#, line), let name = SkillName.slug(parts[0]) {
            return .saveRecent(name: name, count: 1)
        }
        let pattern = #"^(?:save|turn) the last ([a-z]+|[0-9]+) (?:things|requests) (?:as|into) a skill (?:called|named) (.+)$"#
        guard let parts = capture(pattern, line), let name = SkillName.slug(parts[1]) else { return nil }
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        let count = Int(parts[0]) ?? words.firstIndex(of: parts[0].lowercased()).map { $0 + 1 }
        guard let count, count > 0 else { return nil }
        return .saveRecent(name: name, count: count)
    }

    private static func scheduled(_ line: String) -> SkillCommand? {
        let pattern = #"^run (?:my|the) (.+?) skill (daily|every weekday|every weekend|every [a-z]+) at "#
            + #"([0-9]{1,2})(?::([0-9]{2}))?(?:\s*(am|pm))?$"#
        guard let parts = capture(pattern, line), let name = SkillName.slug(parts[0]), var hour = Int(parts[2]) else { return nil }
        let period = parts[4].lowercased()
        if !period.isEmpty {
            guard (1 ... 12).contains(hour) else { return nil }
            hour = hour % 12 + (period == "pm" ? 12 : 0)
        }
        let day = parts[1].lowercased().replacingOccurrences(of: "every ", with: "")
        let days = ["weekday": "weekdays", "weekend": "weekends"][day] ?? day
        let minute = parts[3].isEmpty ? "00" : parts[3]
        guard let schedule = SkillSchedule("\(days) \(hour):\(minute)") else { return nil }
        return .schedule(name: name, schedule)
    }

    private static func named(_ line: String) -> SkillCommand? {
        let forms: [(String, (String) -> SkillCommand)] = [
            (#"^(?:delete|forget|remove) (?:my|the) (.+?) skill$"#, { .delete(name: $0) }),
            (#"^what does my (.+?) skill do$"#, { .show(name: $0) }),
            (#"^(?:run|do|start) (?:my|the) (.+?)(?: skill)?$"#, { .run(name: $0) }),
        ]
        for (pattern, make) in forms {
            if let raw = capture(pattern, line)?.first, let name = SkillName.slug(raw) {
                return make(name)
            }
        }
        return nil
    }

    static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }
}

/// Converts an owner's spoken name to the same naming rules used by the strict frontmatter parser.
public enum SkillName {
    public static func slug(_ spoken: String) -> String? {
        let slug = spoken.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
        guard !slug.isEmpty, slug.unicodeScalars.count <= SkillParser.maxNameLength,
              (try? SkillParser.validateName(slug)) != nil else { return nil }
        return slug
    }
}

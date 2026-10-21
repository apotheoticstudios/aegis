// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/tools/proactive_tools.py
// (parse_approval_response), commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes:
// translated to Swift for Aegis; parses only (the engine applies decisions); targets may also be spoken numbers,
// ordinals, "both" and "everything"; bare "yes"/"no" answer a single proposal.
import Foundation

/// The owner's answer to the morning routine (#286): "1 yes", "yes to 2 and 3", "always no to the second one",
/// "yes all", or OpenJarvis's "abc123def456 yes". Only the owner's own words; never collected content.
public enum ApprovalReply {
    /// One decision about one proposal number, a proposal ID, or every pending proposal.
    public struct Decision: Sendable, Equatable {
        public enum Target: Sendable, Equatable {
            case number(Int)
            case id(String)
            case all
        }

        public let target: Target
        public let approved: Bool
        public let always: Bool
    }

    /// Decisions in the owner's words, in order; empty when the line isn't an answer. `single` is true when exactly
    /// one proposal is pending, so a bare "yes" or "no" answers it.
    public static func parse(_ text: String, single: Bool = false) -> [Decision] {
        let line = normalised(text)
        guard !line.isEmpty, line.unicodeScalars.count <= 200 else { return [] }
        // OpenJarvis's form: "<id> yes", "yes <id>", "always yes <id>", "yes all".
        var decisions: [Decision] = []
        let pattern = #"\b(always\s+)?(yes|no|approve|deny)\s+([a-f0-9]{12}|all)\b|\b([a-f0-9]{12}|all)\s+(always\s+)?(yes|no|approve|deny)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let group = { (index: Int) in Range(match.range(at: index), in: line).map { String(line[$0]) } }
                let target = group(3) ?? group(4) ?? ""
                let decision = group(2) ?? group(6) ?? ""
                decisions.append(Decision(
                    target: target == "all" ? .all : .id(target), approved: ["yes", "approve"].contains(decision),
                    always: group(1) != nil || group(5) != nil
                ))
            }
        }
        if !decisions.isEmpty {
            return decisions
        }
        return spoken(line, single: single)
    }

    /// "Yes to 1 and 3", "always no to the second one", "do all of them", "no to both", "yes".
    private static func spoken(_ line: String, single: Bool) -> [Decision] {
        let pattern = #"^(always\s+)?(yes|yeah|yep|sure|ok|okay|do|approve|no|nope|don't|skip|deny)\b(?:\s+(?:to|for|on))?\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let verb = Range(match.range(at: 2), in: line).map({ String(line[$0]) })
        else { return [] }
        let always = match.range(at: 1).location != NSNotFound
        let approved = !["no", "nope", "don't", "skip", "deny"].contains(verb)
        let rest = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        let words = rest.replacingOccurrences(
            of: #"\b(the|one|ones|item|items|number|of|them|it|please|thanks|and|,)\b"#,
            with: " ",
            options: .regularExpression
        )
        .split { $0 == " " || $0 == "," }.map(String.init)
        if rest.range(of: #"\b(all|both|everything|every one|each)\b"#, options: .regularExpression) != nil {
            return [Decision(target: .all, approved: approved, always: always)]
        }
        let numbers = words.compactMap(number)
        guard numbers.count == words.count else { return [] }
        if numbers.isEmpty {
            // A bare "yes" answers the only proposal; "do" alone is not an answer.
            return single && verb != "do" ? [Decision(target: .all, approved: approved, always: always)] : []
        }
        return numbers.map { Decision(target: .number($0), approved: approved, always: always) }
    }

    private static func number(_ word: String) -> Int? {
        if let value = Int(word), (1 ... 20).contains(value) {
            return value
        }
        let names = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
            "ninth": 9, "tenth": 10, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "two": 2, "three": 3,
            "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "last": 0,
        ]
        guard let value = names[word], value > 0 else { return nil }
        return value
    }

    /// Lowercase, apostrophes straightened, "Aegis," and brackets and end punctuation removed.
    private static func normalised(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[\[\]\{\}\(\)#]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

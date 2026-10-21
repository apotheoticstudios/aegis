import Foundation

/// Text boundaries shared by detection and completion: history and quoted words are never evidence.
enum CommitmentText {
    static func match(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func body(_ event: Event) -> String {
        guard event.source == .email else { return event.body }
        var lines: [String] = []
        for line in event.body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if match(#"^(?:>|On\b.*\bwrote:|From:|-----Original Message-----|Sent from my\b)"#, in: trimmed) != nil {
                break
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func unquoted(_ text: String) -> String {
        let pattern = #""[^"]*(?:"|$)|“[^”]*(?:”|$)|‘(?:[^’]|(?<=\w)’(?=\w))*(?:’|$)|"#
            + #"(?<!\w)'(?:[^']|(?<=\w)'(?=\w))*(?:'(?!\w)|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let masked = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return masked as String
    }

    static func sentences(_ event: Event) -> [String] {
        let text = body(event)
        let masked = unquoted(text)
        guard let expression = try? NSRegularExpression(pattern: #"[.!?](?=\s|$)|\R+"#) else { return [] }
        var start = 0
        var sentences: [String] = []
        let original = text as NSString
        for match in expression.matches(in: masked, range: NSRange(masked.startIndex..., in: masked)) {
            let end = match.range.location + match.range.length
            sentences.append(original.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        sentences.append(original.substring(from: start))
        return sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func excerpt(_ sentence: String) -> String {
        let clean = sentence.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let line = String(clean).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

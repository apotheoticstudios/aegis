import Foundation

/// Several requests in one line (#47): "open Safari, go to apple.com and play music".
public extension CommandPlan {
    /// The most steps in one plan.
    static let maxSteps = 6

    /// The owner's words split into requests, or nil for a single request. A part joins the one before it unless it
    /// reads as a command of its own, so "make a note called salt and pepper" stays one. Free text (a message, a
    /// reminder, an event, a note's title) ends only at "then" or ";", so "remind me to turn off the oven and start
    /// the dishwasher" stays one reminder. Every part must be a command, and there are at most `maxSteps`.
    static func parts(_ text: String, now: Date, calendar: Calendar) -> [String]? {
        let line = ActionCommand.cleaned(text)
        guard line.count <= 600,
              let regex = try? NSRegularExpression(
                  pattern: #"\s*(?:,\s*)?(?:and\s+)?then\s+|\s*;\s*|\s*,\s*(?:and\s+)?|\s+and\s+"#,
                  options: .caseInsensitive
              )
        else { return nil }
        let isCommand = { (part: String) in
            ActionCommand.parse(part, now: now, calendar: calendar) != nil || MessageCommand.parse(part) != nil
                || looksLikeCommand(part)
        }
        let freeText = { (part: String) -> Bool in
            switch ActionCommand.parse(part, now: now, calendar: calendar) {
            case .reminder, .event, .automate(.notesNewNote, _): true
            default: MessageCommand.parse(part) != nil
            }
        }
        var found: [String] = []
        var current = ""
        var start = line.startIndex
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            let separator = String(line[range])
            let piece = String(line[start ..< range.lowerBound])
            start = range.upperBound
            current += piece
            let next = String(line[range.upperBound...])
            // Split here only if what follows starts a command of its own (checked up to the next separator).
            let following = regex.firstMatch(in: next, range: NSRange(next.startIndex..., in: next))
                .flatMap { Range($0.range, in: next) }.map { String(next[..<$0.lowerBound]) } ?? next
            let strong = separator.range(of: #"then|;"#, options: [.regularExpression, .caseInsensitive]) != nil
            if !current.isEmpty, isCommand(following), strong || !freeText(current) {
                found.append(current)
                current = ""
            } else {
                current += separator
            }
        }
        current += line[start...]
        found.append(current)
        let steps = found.map { $0.trimmingCharacters(in: .whitespaces) }
        guard (2 ... maxSteps).contains(steps.count), steps.allSatisfy(isCommand) else { return nil }
        return steps
    }
}

import Foundation

public extension Chat {
    /// The owner's request without what people say around one (#203): "Sweet. What's on today?", "Jarvis, open Safari",
    /// "Okay so, run Work", "what's on tomorrow, mate?". Without this, "sweet" was searched for as if it were the topic.
    /// Yes and no stay (they answer a card), nothing goes that would leave less than two words, and a name at the end goes
    /// only after a comma: "run Backup Friday" and "I lent it to Friday" keep theirs. `name` is Aegis's current name.
    static func request(_ text: String, name: String) -> String {
        let me = "(?:aegis|" + NSRegularExpression.escapedPattern(for: name.lowercased()) + ")"
        let lead = #"^\s*(?:(?:hey|hi|oi|yo|ok|okay)\s+"# + me + #"[,.!:]?\s+|"# + me + #"[,.!:]+\s*|"#
            + #"(?:hey|hi|oi|yo|sweet|cool|nice|great|awesome|perfect|lovely|brilliant|excellent|good|right|alright|all right|ok|"#
            + #"okay|sure|thanks|thank you|cheers|ta|so|well|um+|uh+|er+|hm+|oh|ah|anyway|mate)[,.!…:-]+\s*|"#
            + #"(?:so|well|um+|uh+|er+|hm+|anyway|now|then|ok so|okay so|alright so|right so)[,.!…:-]*\s+)"#
        func words(_ line: String) -> Int {
            line.split(whereSeparator: \.isWhitespace).count
        }
        var line = text
        while let range = line.range(of: lead, options: [.regularExpression, .caseInsensitive]),
              words(String(line[range.upperBound...])) >= 2
        {
            line = String(line[range.upperBound...])
        }
        let trailing = line.replacingOccurrences(
            of: #",\s*(?:"# + me + #"|mate)(?=[?.!]*\s*$)"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        return words(trailing) >= 2 ? trailing : line
    }
}

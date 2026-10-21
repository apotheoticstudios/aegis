import Foundation

/// Citation-local lexical rubric, not semantic entailment. Role swaps and new lowercase names need human review.
public enum BriefFacts {
    public static let categories = ["names", "handles", "amounts", "numbers", "weekdays", "dates", "actions"]
    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private static let months = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    ]
    private static let framing = Set((
        "i you your we our they their today tomorrow yesterday this that the a an it its please reminder request message "
            + "email notification invoice card payment important no nothing multiple several some many"
    ).split(separator: " ").map(String.init))
    private static let numberWords = "zero one two three four five six seven eight nine ten eleven twelve".split(separator: " ")
        .map(String.init)
    private static let wordPattern = #"[^\W\d_]+(?:['’][^\W\d_]+)?"#
    private static let actionGroups = [
        "call calls called calling", "pay pays paid paying payment", "send sends sent sending",
        "forward forwards forwarded forwarding", "unlock unlocks unlocked unlocking", "delete deletes deleted deleting",
        "buy buys bought purchase purchased", "mark marks marked marking", "ignore ignores ignored ignoring",
        "bring brings bringing brought",
    ]

    /// Unsupported entity counts, grounded only in the item's cited source content and event times.
    public static func unsupported(_ text: String, citedEvents: [Event]) -> [String: Int] {
        let wanted = entities(text)
        var available = emptyFacts()
        for event in citedEvents {
            for field in [event.sender ?? "", event.title ?? "", event.body, ContractTime.format(event.eventTime)] {
                for (kind, values) in entities(field) {
                    available[kind, default: []].formUnion(values)
                }
            }
            if event.source == .email || event.source == .imessage || event
                .source == .sms
            {
                available["actions", default: []].insert("send")
            }
            for field in [event.sender ?? "", event.title ?? "", event.body] {
                available["names", default: []].formUnion(matches(wordPattern, field).map(folded))
            }
        }
        return Dictionary(uniqueKeysWithValues: categories.map { ($0, (wanted[$0] ?? []).subtracting(available[$0] ?? []).count) })
    }

    private static func emptyFacts() -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0, Set<String>()) })
    }

    private static func decimal(_ text: String) -> String {
        // Exact, unbounded decimal spelling: Foundation Decimal's 38-digit precision would
        // let different large invented numbers collapse to the same fact.
        let ascii = text.filter { $0 != "," }.map { character in
            character.wholeNumberValue.map(String.init) ?? String(character)
        }.joined()
        let parts = ascii.split(separator: ".", omittingEmptySubsequences: false)
        let fractionalCount = parts.count > 1 ? parts[1].count : 0
        var digits = String(ascii.filter { $0 != "." }.drop(while: { $0 == "0" }))
        guard !digits.isEmpty else { return "0" }
        let trailing = digits.reversed().prefix(while: { $0 == "0" }).count
        digits = String(digits.dropLast(trailing))
        let exponent = trailing - fractionalCount
        let adjusted = exponent + digits.count - 1
        if exponent > 0 || adjusted < -6 {
            let coefficient = String(digits.prefix(1)) + (digits.count > 1 ? "." + digits.dropFirst() : "")
            return coefficient + "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
        }
        let point = digits.count + exponent
        if point <= 0 {
            return "0." + String(repeating: "0", count: -point) + digits
        }
        if point == digits.count {
            return digits
        }
        return String(digits.prefix(point)) + "." + digits.dropFirst(point)
    }

    private static func dateValue(_ text: String) -> String {
        let parts = matches(#"\d+|[a-z]+"#, text.lowercased())
        guard parts.count == 3 else { return folded(text) }
        var year: Int?, month: Int?, day: Int?
        if text.contains("-") {
            year = Int(parts[0]); month = Int(parts[1]); day = Int(parts[2])
        } else if text.contains("/") {
            day = Int(parts[0]); month = Int(parts[1]); year = Int(parts[2])
        } else if let index = months.firstIndex(of: parts[0]) {
            month = index + 1; day = Int(parts[1]); year = Int(parts[2])
        } else {
            day = Int(parts[0]); month = months.firstIndex(of: parts[1]).map { $0 + 1 }; year = Int(parts[2])
        }
        guard let year, let month, let day, (1 ... 9999).contains(year) else { return folded(text) }
        let value = String(format: "%04d-%02d-%02d", year, month, day)
        return ContractTime.parse(value + "T00:00:00Z") != nil ? value : folded(text)
    }

    private static func entities(_ text: String) -> [String: Set<String>] {
        var facts = emptyFacts()
        var remaining = text.precomposedStringWithCanonicalMapping
        let monthPattern = months.joined(separator: "|")
        let datePattern = #"\b\d{4}-\d{2}-\d{2}(?=$|T|\W)|\b\d{1,2}/\d{1,2}/\d{4}\b|\b(?:"# + monthPattern
            + #")\s+\d{1,2},?\s+\d{4}\b|\b\d{1,2}\s+(?:"# + monthPattern + #")\s+\d{4}\b"#
        let patterns: [(String, String, (String) -> String)] = [
            (datePattern, "dates", dateValue),
            (#"[\w.+-]+@[\w.-]+\.[\w-]+"#, "handles", folded),
            (#"(?:[$€£]|\b(?:USD|AUD|EUR|GBP)\s*)\s*\d[\d,]*(?:\.\d+)?"#, "amounts", { value in
                let currency = value.replacingOccurrences(of: #"[\d,.\s]"#, with: "", options: .regularExpression)
                return folded(currency) + ":" + decimal(matches(#"\d[\d,.]*"#, value).first ?? "0")
            }),
            (#"(?<!\w)(?:\+\d[\d ()-]{5,}\d|\d{8,})(?!\w)"#, "handles", { value in
                String(String.UnicodeScalarView(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }))
            }),
            (#"(?<!\w)\d+(?:,\d{3})*(?:\.\d+)?(?!\w)"#, "numbers", decimal),
        ]
        for (pattern, kind, convert) in patterns {
            for value in matches(pattern, remaining, insensitive: true) {
                facts[kind, default: []].insert(convert(value))
            }
            remaining = remaining.replacingOccurrences(of: "(?i)" + pattern, with: " ", options: .regularExpression)
        }
        for var word in matches(wordPattern, remaining) {
            if word.hasSuffix("'s") || word.hasSuffix("’s") {
                word = String(word.dropLast(2))
            }
            let lower = folded(word)
            if let number = numberWords.firstIndex(of: lower) {
                facts["numbers", default: []].insert(String(number))
            } else if let day = weekdays.first(where: { lower == $0 || lower == String($0.prefix(3)) }) {
                facts["weekdays", default: []].insert(day)
            } else if months.contains(lower) {
                facts["dates", default: []].insert(lower)
            } else if word.unicodeScalars.first?.properties.isUppercase == true, !framing.contains(lower) {
                facts["names", default: []].insert(lower)
            }
            for group in actionGroups {
                let forms = group.split(separator: " ").map(String.init)
                if forms.contains(lower), let action = forms.first {
                    facts["actions", default: []].insert(action)
                }
            }
        }
        return facts
    }
}

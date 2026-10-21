import Foundation

/// Instant answers that need no model (#227): the time and date, days until a date, arithmetic and percentages, and
/// common unit conversions. Deterministic and exact; nil for anything else, which goes to the conversation.
public enum QuickAnswer {
    public static func answer(_ text: String, now: Date, calendar: Calendar) -> String? {
        let line = cleaned(text)
        guard !line.isEmpty, line.count <= 120 else { return nil }
        if line.range(
            of: #"^(?:what(?:'s| is) the time|what time is it|whats the time)(?: now| right now)?$"#,
            options: .regularExpression
        ) != nil {
            return "It's " + format("h:mm a", now, calendar) + "."
        }
        if line.range(
            of: #"^(?:what(?:'s| is) (?:the date|today'?s date)|whats the date|what day is it|what(?:'s| is) today)(?: today)?$"#,
            options: .regularExpression
        ) != nil {
            return "It's " + format("EEEE d MMMM yyyy", now, calendar) + "."
        }
        if let target = capture(#"^how (?:many days|long) (?:is it )?(?:until|till|til|to|before) (.+)$"#, line) {
            return daysUntil(target, now: now, calendar: calendar)
        }
        if let conversion = convert(line) {
            return conversion
        }
        return arithmetic(line)
    }

    // MARK: - Days until

    private static func daysUntil(_ target: String, now: Date, calendar: Calendar) -> String? {
        let named: [String: (month: Int, day: Int, name: String)] = [
            "christmas": (12, 25, "Christmas"), "christmas day": (12, 25, "Christmas"), "boxing day": (12, 26, "Boxing Day"),
            "new year": (1, 1, "New Year's Day"), "new year's": (1, 1, "New Year's Day"), "new years": (1, 1, "New Year's Day"),
            "new year's day": (1, 1, "New Year's Day"), "halloween": (10, 31, "Halloween"), "valentine's day": (2, 14, "Valentine's Day"),
            "valentines day": (2, 14, "Valentine's Day"), "australia day": (1, 26, "Australia Day"), "anzac day": (4, 25, "Anzac Day"),
        ]
        let key = target.replacingOccurrences(of: #"^the "#, with: "", options: .regularExpression)
        var month: Int
        var day: Int
        var name: String
        if let found = named[key] {
            (month, day, name) = found
        } else if let parsed = monthDay(key) {
            (month, day) = parsed
            name = "\(day) " + [
                "January",
                "February",
                "March",
                "April",
                "May",
                "June",
                "July",
                "August",
                "September",
                "October",
                "November",
                "December",
            ][month - 1]
        } else {
            return nil
        }
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        // Calendar.date normalises invalid dates (31 April becomes 1 May); validate each component.
        // Looking ahead also finds the next real leap day rather than returning 1 March.
        guard let date = (year ... year + 8).lazy.compactMap({ candidate -> Date? in
            guard let date = calendar.date(from: DateComponents(year: candidate, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day,
                  date >= today
            else { return nil }
            return date
        }).first else { return nil }
        let days = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        return switch days {
        case 0: "\(name) is today."
        case 1: "\(name) is tomorrow."
        default: "It's \(days) days until \(name)."
        }
    }

    /// "25 december", "december 25", "the 3rd of march" → (month, day).
    private static func monthDay(_ text: String) -> (Int, Int)? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let fullMonths = [
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
        let words = text.replacingOccurrences(of: #"(\d+)(?:st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: " of ", with: " ").split(separator: " ").map(String.init)
        guard words.count == 2 else { return nil }
        for (dayWord, monthWord) in [(words[0], words[1]), (words[1], words[0])] {
            if let day = Int(dayWord), (1 ... 31).contains(day),
               let month = months.firstIndex(of: monthWord) ?? fullMonths.firstIndex(of: monthWord)
            {
                return (month + 1, day)
            }
        }
        return nil
    }

    // MARK: - Conversions

    private struct Unit {
        let names: [String]
        let dimension: String
        /// How many base units one of these is (temperature is handled on its own).
        let factor: Double
        let singular: String
        let plural: String
    }

    private static let units: [Unit] = [
        Unit(
            names: ["km", "kms", "kilometre", "kilometres", "kilometer", "kilometers"],
            dimension: "length",
            factor: 1000,
            singular: "kilometre",
            plural: "kilometres"
        ),
        Unit(names: ["mile", "miles", "mi"], dimension: "length", factor: 1609.344, singular: "mile", plural: "miles"),
        Unit(names: ["m", "metre", "metres", "meter", "meters"], dimension: "length", factor: 1, singular: "metre", plural: "metres"),
        Unit(
            names: ["cm", "centimetre", "centimetres", "centimeter", "centimeters"],
            dimension: "length",
            factor: 0.01,
            singular: "centimetre",
            plural: "centimetres"
        ),
        Unit(
            names: ["mm", "millimetre", "millimetres", "millimeter", "millimeters"],
            dimension: "length",
            factor: 0.001,
            singular: "millimetre",
            plural: "millimetres"
        ),
        Unit(names: ["ft", "foot", "feet"], dimension: "length", factor: 0.3048, singular: "foot", plural: "feet"),
        Unit(names: ["inch", "inches"], dimension: "length", factor: 0.0254, singular: "inch", plural: "inches"),
        Unit(names: ["yard", "yards", "yd"], dimension: "length", factor: 0.9144, singular: "yard", plural: "yards"),
        Unit(
            names: ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms"],
            dimension: "mass",
            factor: 1000,
            singular: "kilogram",
            plural: "kilograms"
        ),
        Unit(names: ["g", "gram", "grams"], dimension: "mass", factor: 1, singular: "gram", plural: "grams"),
        Unit(names: ["lb", "lbs", "pound", "pounds"], dimension: "mass", factor: 453.59237, singular: "pound", plural: "pounds"),
        Unit(names: ["oz", "ounce", "ounces"], dimension: "mass", factor: 28.349523125, singular: "ounce", plural: "ounces"),
        Unit(names: ["stone", "stones", "st"], dimension: "mass", factor: 6350.29318, singular: "stone", plural: "stone"),
        Unit(names: ["l", "litre", "litres", "liter", "liters"], dimension: "volume", factor: 1000, singular: "litre", plural: "litres"),
        Unit(
            names: ["ml", "millilitre", "millilitres", "milliliter", "milliliters"],
            dimension: "volume",
            factor: 1,
            singular: "millilitre",
            plural: "millilitres"
        ),
        Unit(names: ["gallon", "gallons", "gal"], dimension: "volume", factor: 3785.411784, singular: "US gallon", plural: "US gallons"),
        Unit(names: ["cup", "cups"], dimension: "volume", factor: 250, singular: "cup", plural: "cups"),
        Unit(
            names: ["km/h", "kph", "kmh", "kilometres per hour", "kilometers per hour"],
            dimension: "speed",
            factor: 1 / 3.6,
            singular: "kilometre per hour",
            plural: "kilometres per hour"
        ),
        Unit(names: ["mph", "miles per hour"], dimension: "speed", factor: 0.44704, singular: "mile per hour", plural: "miles per hour"),
        Unit(
            names: ["c", "°c", "celsius", "degrees celsius", "degree celsius", "degrees c"],
            dimension: "temperature",
            factor: 1,
            singular: "degree Celsius",
            plural: "degrees Celsius"
        ),
        Unit(
            names: ["f", "°f", "fahrenheit", "degrees fahrenheit", "degree fahrenheit", "degrees f"],
            dimension: "temperature",
            factor: 1,
            singular: "degree Fahrenheit",
            plural: "degrees Fahrenheit"
        ),
    ]

    private static func unit(_ name: String) -> Unit? {
        let key = name.trimmingCharacters(in: .whitespaces)
        return units.first { $0.names.contains(key) }
    }

    /// "10 km in miles", "convert 30 c to f", "how many pounds in 5 kg".
    private static func convert(_ line: String) -> String? {
        let amount = #"(-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)"#
        var value: Double?
        var from: Unit?
        var to: Unit?
        if let parts = captures(
            #"^(?:convert |what(?:'s| is) |whats |how much is |how many \S+(?: \S+)? is )?"# + amount +
                #"\s*([a-z°/ ]+?)\s+(?:in|to|into|in to)\s+([a-z°/ ]+)$"#,
            line
        ) {
            value = Double(parts[0].replacingOccurrences(of: ",", with: ""))
            from = unit(parts[1])
            to = unit(parts[2])
        } else if let parts = captures(#"^how many ([a-z°/ ]+?) (?:are |is )?(?:in|to) "# + amount + #"\s*([a-z°/ ]+)$"#, line) {
            to = unit(parts[0])
            value = Double(parts[1].replacingOccurrences(of: ",", with: ""))
            from = unit(parts[2])
        }
        guard let value, let from, let to, from.dimension == to.dimension, from.singular != to.singular else { return nil }
        let result: Double = if from.dimension == "temperature" {
            from.singular.hasSuffix("Celsius") ? value * 9 / 5 + 32 : (value - 32) * 5 / 9
        } else {
            value * from.factor / to.factor
        }
        return "\(number(value)) \(value == 1 ? from.singular : from.plural) is \(number(result)) \(result == 1 ? to.singular : to.plural)."
    }

    // MARK: - Arithmetic

    /// "what's 15% of 240", "12 times 37", "square root of 144", "(3 + 4) * 2".
    private static func arithmetic(_ line: String) -> String? {
        var expression = line.replacingOccurrences(
            of: #"^(?:what(?:'s| is)|whats|calculate|compute|work out|how much is)\s+"#,
            with: "",
            options: .regularExpression
        )
        let words: [(String, String)] = [
            (#"(\d+(?:\.\d+)?)\s*(?:%|percent|per cent) of"#, "($1/100)*"), (#"square root of"#, "sqrt "),
            (#"to the power of"#, "^"), (#"multiplied by"#, "*"), (#"divided by"#, "/"), (#"\btimes\b"#, "*"),
            (#"\bplus\b"#, "+"), (#"\bminus\b"#, "-"), (#"\bover\b"#, "/"), (#"\bsquared\b"#, "^2"), (#"\bcubed\b"#, "^3"),
            (#"(\d)\s*x\s*(\d)"#, "$1*$2"), ("×", "*"), ("÷", "/"),
        ]
        for (pattern, swap) in words {
            expression = expression.replacingOccurrences(of: pattern, with: swap, options: .regularExpression)
        }
        if let grouping = try? NSRegularExpression(pattern: #"\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b"#) {
            for match in grouping.matches(in: expression, range: NSRange(expression.startIndex..., in: expression)).reversed() {
                if let range = Range(match.range, in: expression) {
                    expression.replaceSubrange(range, with: expression[range].replacingOccurrences(of: ",", with: ""))
                }
            }
        }
        expression = expression.replacingOccurrences(of: " ", with: "")
        // Only numbers, operators and brackets, with at least one operator: a sum, not a sentence or a lone number.
        guard expression.range(of: #"^[0-9.+\-*/^()sqrt]+$"#, options: .regularExpression) != nil,
              expression.range(of: #"[+\-*/^]|sqrt"#, options: .regularExpression) != nil,
              expression.range(of: #"\d"#, options: .regularExpression) != nil
        else { return nil }
        var parser = Parser(Array(expression))
        guard let value = parser.parse() else { return nil }
        guard value.isFinite else {
            return parser.dividedByZero ? "That's undefined: you can't divide by zero."
                : "That's undefined or too large to calculate."
        }
        return "That's \(number(value))."
    }

    /// A small recursive-descent calculator: + - * / ^, brackets, unary minus and sqrt.
    private struct Parser {
        let characters: [Character]
        var index = 0
        var dividedByZero = false

        init(_ characters: [Character]) {
            self.characters = characters
        }

        mutating func parse() -> Double? {
            guard let value = sum(), index == characters.count else { return nil }
            return value
        }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let next = peek(), next == "+" || next == "-" {
                index += 1
                guard let right = product() else { return nil }
                value = next == "+" ? value + right : value - right
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = unary() else { return nil }
            while let next = peek(), next == "*" || next == "/" {
                index += 1
                guard let right = unary() else { return nil }
                if next == "/", right == 0 {
                    dividedByZero = true
                }
                value = next == "*" ? value * right : value / right
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            if peek() == "^" {
                index += 1
                guard let exponent = unary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek() == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if characters[index...].starts(with: "sqrt") {
                index += 4
                return unary().flatMap { $0 >= 0 ? $0.squareRoot() : nil }
            }
            return power()
        }

        private mutating func primary() -> Double? {
            if peek() == "(" {
                index += 1
                guard let value = sum(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while let next = peek(), next.isNumber || next == "." {
                index += 1
            }
            return index > start ? Double(String(characters[start ..< index])) : nil
        }

        private func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }
    }

    // MARK: - Helpers

    private static func cleaned(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^\s*(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:please|can you tell me|could you tell me|tell me)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s?!.]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",?\s*please$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func number(_ value: Double) -> String {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_AU")
        if value != 0, abs(value) < 1e-12 {
            format.numberStyle = .scientific
            format.maximumFractionDigits = 4
        } else {
            format.numberStyle = .decimal
            format.maximumFractionDigits = value != 0 && abs(value) < 1
                ? min(12, max(4, Int(ceil(-log10(abs(value)))) + 3)) : 2
        }
        return format.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_AU")
        format.dateFormat = pattern
        return format.string(from: date)
    }

    private static func capture(_ pattern: String, _ line: String) -> String? {
        captures(pattern, line)?.first
    }

    private static func captures(_ pattern: String, _ line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }
}

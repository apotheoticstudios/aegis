import Foundation

/// UTC timestamps in the contract's one format, `YYYY-MM-DDTHH:MM:SS[.fraction]Z`.
///
/// Parsed and written with plain arithmetic (no calendars, formatters or Apple-only APIs), so the
/// result is identical on macOS and Linux.
public enum ContractTime {
    /// The date for a contract timestamp, or nil when the text doesn't match the format or names an impossible time.
    public static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = digits(bytes, 0 ..< 4), let month = digits(bytes, 5 ..< 7), let day = digits(bytes, 8 ..< 10),
              let hour = digits(bytes, 11 ..< 13), let minute = digits(bytes, 14 ..< 16), let second = digits(bytes, 17 ..< 19)
        else { return nil }
        var fraction = 0.0
        if bytes.count > 20 {
            guard bytes[19] == UInt8(ascii: "."), bytes.count > 21, digits(bytes, 20 ..< bytes.count - 1) != nil,
                  let fractionDigits = String(bytes: bytes[20 ..< bytes.count - 1], encoding: .ascii),
                  let value = Double("0." + fractionDigits)
            else { return nil }
            fraction = value
        }
        guard (1 ... 12).contains(month), (1 ... daysIn(month: month, year: year)).contains(day),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 59).contains(second)
        else { return nil }
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// The contract timestamp for a date: whole seconds when exact, otherwise up to microseconds.
    public static func format(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var whole = interval.rounded(.down)
        var micros = Int(((interval - whole) * 1_000_000).rounded())
        if micros == 1_000_000 {
            whole += 1
            micros = 0
        }
        let total = Int(whole)
        let days = Int((Double(total) / 86400).rounded(.down))
        let secondsOfDay = total - days * 86400
        let (year, month, day) = civilFromDays(days)
        var text = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T" + pad(secondsOfDay / 3600, 2) + ":"
            + pad(secondsOfDay % 3600 / 60, 2) + ":" + pad(secondsOfDay % 60, 2)
        if micros > 0 {
            var fraction = pad(micros, 6)
            while fraction.hasSuffix("0") {
                fraction.removeLast()
            }
            text += "." + fraction
        }
        return text + "Z"
    }

    private static func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0
        for index in range {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return range.isEmpty ? nil : value
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Howard Hinnant's days-from-civil algorithms (proleptic Gregorian calendar, day 0 = 1970-01-01).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // swiftlint:disable:next large_tuple
    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex + (monthIndex < 10 ? 3 : -9)
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

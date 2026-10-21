import Foundation

/// Metadata and readable content from one Apple Mail message. All strings are inert collected data.
public struct MailMessage: Sendable, Equatable {
    /// The source of the selected timestamp.
    public enum DateSource: String, Sendable {
        /// A valid Date header.
        case header
        /// The first (topmost) Received hop, when its date is valid.
        case received
        /// The caller's Envelope Index timestamp.
        case index
    }

    /// Availability of readable message content.
    public enum Content: String, Sendable {
        /// Readable content from a fully downloaded message, including an empty text part.
        case complete
        /// Readable content from a partially downloaded message.
        case preview
        /// No readable content, or an encrypted message.
        case unavailable
    }

    /// Message-ID text, including malformed identifiers; nil when absent.
    public let messageID: String?
    /// Decoded From header; nil when absent, empty when explicitly empty.
    public let from: String?
    /// Decoded recipient entries, retaining display names and malformed text.
    public let to: [String]
    /// Decoded Subject header; nil when absent, empty when explicitly empty.
    public let subject: String?
    /// Selected timestamp, or nil when every source is unavailable or invalid.
    public let date: Date?
    /// Source of `date`, or nil when no date could be selected.
    public let dateSource: DateSource?
    /// First plain text part, otherwise the first HTML part converted to text.
    public let body: String
    /// Availability of `body`.
    public let content: Content
    /// Whether the caller identified a partial download.
    public let truncated: Bool
    /// Whether any parsed MIME part declares encrypted content.
    public let encrypted: Bool
    /// Whether no non-attachment plain text or HTML part was found; an empty text part counts as present.
    public let attachmentOnly: Bool
    /// Bulk or marketing mail: a List-Unsubscribe or List-Id header, or Precedence bulk, list or junk.
    public let bulk: Bool
}

/// Framing failures, carrying no message content.
public enum EmlxError: Error, Sendable, Equatable {
    /// The first line is not a decimal count followed by a newline within 64 bytes.
    case invalidByteCount
    /// The declared RFC 822 message extends beyond the supplied data.
    case truncatedMessage
}

/// Pure parsing of Apple Mail's byte-count wrapper and RFC 822 message.
public enum Emlx {
    /// Parses `.emlx`, `.partial.emlx`, or `.emlxpart` bytes without accessing any stores.
    ///
    /// The caller determines `partial` from its download metadata or filename and supplies the
    /// already-converted index date. A missing or malformed plist trailer is ignored, as in Python.
    /// Only framing failures throw; malformed message headers and bodies remain parseable.
    public static func parse(_ data: Data, partial: Bool = false, indexDate: Date? = nil) throws(EmlxError) -> MailMessage {
        let bytes = [UInt8](data)
        guard let newline = bytes.prefix(64).firstIndex(of: 10) else { throw .invalidByteCount }
        // Replacement decoding keeps malformed count bytes on the typed framing-error path.
        // swiftlint:disable:next optional_data_string_conversion
        let countText = String(decoding: bytes[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !countText.isEmpty, countText.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { throw .invalidByteCount }
        let start = newline + 1
        guard let count = Int(countText), count <= bytes.count - start else { throw .truncatedMessage }
        let part = MIME.parse(bytes, range: start ..< (start + count))
        let headerDate = MailDate.parse(part.headers.first("date"))
        let receivedDate = MailDate.parse(
            part.headers.first("received")?.split(separator: ";", omittingEmptySubsequences: false).last.map(String.init)
        )
        let date = headerDate ?? receivedDate ?? indexDate
        let source: MailMessage
            .DateSource? = headerDate != nil ? .header : receivedDate != nil ? .received : indexDate != nil ? .index : nil
        let text = part.plain ?? part.html
        let body = part.encrypted ? "" : text ?? ""
        let content: MailMessage.Content = partial ? (body.isEmpty ? .unavailable : .preview)
            : (part.encrypted || text == nil ? .unavailable : .complete)
        return MailMessage(
            messageID: part.headers.first("message-id"), from: part.headers.first("from"),
            to: part.headers.values("to").flatMap(MailHeaders.recipients), subject: part.headers.first("subject"),
            date: date, dateSource: source, body: body, content: content, truncated: partial,
            encrypted: part.encrypted, attachmentOnly: text == nil,
            bulk: part.headers.first("list-unsubscribe") != nil || part.headers.first("list-id") != nil
                || ["bulk", "list", "junk"].contains(
                    part.headers.first("precedence")?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                )
        )
    }
}

enum MailDate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        var fields = withoutComments(text).split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        if let first = fields.first, Int(first) == nil {
            fields.removeFirst()
        }
        guard fields.count >= 4, let day = Int(fields[0]), let month =
            ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
                .firstIndex(of: fields[1].lowercased()), var year = Int(fields[2]) else { return nil }
        if year < 100 {
            year += year < 69 ? 2000 : 1900
        }
        guard let clock = clock(fields[3]), let offset = offset(fields.count > 4 ? fields[4] : "UTC"),
              (1 ... 31).contains(day), (1 ... 9999).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(
            year: year,
            month: month + 1,
            day: day,
            hour: clock.hour,
            minute: clock.minute,
            second: clock.second
        )
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else { return nil }
        return date.addingTimeInterval(TimeInterval(-offset))
    }

    private static func withoutComments(_ text: String) -> String {
        // RFC 5322 comments are not part of the date. Ignore nested comments and escaped characters.
        var clean = "", depth = 0, escaped = false
        for char in text {
            if escaped {
                escaped = false; continue
            }
            if char == "\\", depth > 0 {
                escaped = true; continue
            }
            if char == "(" {
                depth += 1; continue
            }
            if char == ")", depth > 0 {
                depth -= 1; continue
            }
            if depth == 0 {
                clean.append(char)
            }
        }
        return clean
    }

    private struct Clock {
        let hour: Int
        let minute: Int
        let second: Int
    }

    private static func clock(_ text: String) -> Clock? {
        let clock = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(clock.count), let hour = Int(clock[0]), let minute = Int(clock[1]),
              let second = clock.count == 3 ? Int(clock[2]) : 0,
              (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 59).contains(second) else { return nil }
        return Clock(hour: hour, minute: minute, second: second)
    }

    private static func offset(_ text: String) -> Int? {
        let zone = text.uppercased()
        let named = [
            "UT": 0,
            "UTC": 0,
            "GMT": 0,
            "Z": 0,
            "EST": -18000,
            "EDT": -14400,
            "CST": -21600,
            "CDT": -18000,
            "MST": -25200,
            "MDT": -21600,
            "PST": -28800,
            "PDT": -25200,
        ]
        var offset = named[zone] ?? 0 // Python treats unknown zones and -0000 as UTC.
        if zone.first == "+" || zone.first == "-" {
            let digits = zone.dropFirst()
            guard digits.count == 4, digits.allSatisfy(\.isNumber),
                  let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                  hours < 24, minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        return offset
    }
}

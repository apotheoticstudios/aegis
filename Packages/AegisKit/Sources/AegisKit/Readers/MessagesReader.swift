import Foundation

/// Streams standalone Messages/SMS records; associations, system items and unsent rows are reported.
public enum MessagesReader {
    private static let nanosecondsThreshold: Double = 100_000_000_000_000
    private static let optionalColumns = [
        "associated_message_type", "date_edited", "item_type", "is_system_message", "date_retracted",
    ]

    /// Reads a supplied store; with `onItem`, only counts accumulate in the result.
    public static func read(
        _ path: URL, now: Date = Date(), since: Date? = nil, busyTimeout: TimeInterval = 5,
        onItem: ((ReadItem) throws -> Void)? = nil
    ) throws -> ReadResult {
        try ReaderBase.scan(path, reader: iterate, now: now, since: since, busyTimeout: busyTimeout, onItem: onItem)
    }

    /// Emits each message once, choosing its first chat by chat row ID. Optional old-layout columns default to zero.
    public static func iterate(
        _ connection: SQLiteConnection, now: Date, since: Date? = nil, emit: (ReadItem) throws -> Void
    ) throws {
        let found = try ReaderBase.supportedSchema {
            let columns = try connection.require(
                "message", columns: ["guid", "text", "attributedBody", "handle_id", "service", "date", "is_from_me"]
            )
            try connection.require("handle", columns: ["id"])
            try connection.require("chat", columns: ["guid", "display_name"])
            try connection.require("chat_message_join", columns: ["chat_id", "message_id"])
            return columns
        }
        let optional = optionalColumns.map { (found.contains($0) ? "m.\($0)" : "0") + " AS \($0)" }.joined(separator: ", ")
        var query = """
        SELECT m.ROWID AS rowid, m.guid, m.text, m.attributedBody, m.handle_id, h.id AS handle,
        m.service, m.date, m.is_from_me, \(optional), c.guid AS chat_guid, c.display_name
        FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN chat c ON c.ROWID = j.chat_id
        """
        var bindings: [SQLiteValue] = []
        if let since {
            let seconds = ReaderBase.cocoaSeconds(since).rounded(.towardZero)
            query += " WHERE (m.date > ? AND m.date >= ?) OR (m.date <= ? AND m.date >= ?)"
            bindings = [.real(nanosecondsThreshold), .real(seconds * 1e9), .real(nanosecondsThreshold), .real(seconds)]
        }
        let captured = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var previous: SQLiteValue?
        try connection.query(query + " ORDER BY m.ROWID, j.chat_id", bindings: bindings) { row in
            guard row["rowid"] != previous else { return }
            previous = row["rowid"]
            try readRow(row, now: now, captured: captured, emit: emit)
        }
    }

    private static func readRow(_ row: SQLiteRow, now: Date, captured: Date, emit: (ReadItem) throws -> Void) throws {
        let source: Event.Source = row["service"]?.readerText == "SMS" ? .sms : .imessage
        let guid = row["guid"]?.readerText.flatMap { $0.isEmpty ? nil : $0 }
        func problem(_ code: String, note: String = "") throws {
            try emit(.problem(ReadProblem(code: code, source: source.rawValue, record: guid ?? "(null)", note: note)))
        }
        if try skipRow(row, problem: problem) {
            return
        }
        guard let guid else { return try problem("missing_guid", note: "a message row whose guid is NULL") }
        let stamp = ReaderBase.number(row["date"]) ?? 0
        guard stamp != 0 else { return try problem("missing_timestamp") }
        guard let moment = CocoaTime.date(fromSeconds: abs(stamp) > nanosecondsThreshold ? stamp / 1e9 : stamp) else {
            return try problem("timestamp_out_of_range")
        }
        let fromMe = row["is_from_me"]?.readerTruthy == true
        let sender = fromMe ? "me" : row["handle"]?.readerText
        if sender == nil {
            try problem("missing_handle", note: "handle_id \(row["handle_id"]?.readerDescription ?? "None") has no handle row")
        }
        let thread = row["chat_guid"]?.readerText
        if thread == nil {
            try problem("chat_missing")
        }
        let decoded = try readBody(row, problem: problem)
        let body = decoded.text
        var flags = decoded.flags
        if row["date_retracted"]?.readerTruthy == true, body.isEmpty {
            return try problem("unsent_skipped")
        }
        if row["date_edited"]?.readerTruthy == true {
            flags.append(.edited)
        }
        var event = ReaderBase.makeEvent(
            source: source, sourceRecordID: guid, eventTime: moment, eventTimeSource: .sent,
            captureTime: captured, body: body, content: decoded.content, route: .chatDB, appID: "com.apple.MobileSMS",
            sender: sender, threadID: thread, title: row["display_name"]?.readerText.flatMap { $0.isEmpty ? nil : $0 },
            flags: flags + ReaderBase.skewFlags(moment, now: now)
        )
        event.direction = fromMe ? .outgoing : .incoming
        event.senderHandle = sender == "me" ? nil : sender.flatMap { $0.isEmpty ? nil : $0 }
        try emit(.event(event))
    }

    private static func skipRow(_ row: SQLiteRow, problem: (String, String) throws -> Void) throws -> Bool {
        let kind = ReaderBase.number(row["associated_message_type"]) ?? 0
        let association = kind == 1000 || kind == 4000 || (kind.rounded() == kind && (2000 ..< 4000).contains(kind))
        if association {
            try problem("reaction_skipped", "associated_message_type \(row["associated_message_type"]?.readerDescription ?? "0")")
            return true
        }
        if row["item_type"]?.readerTruthy == true || row["is_system_message"]?.readerTruthy == true {
            try problem("system_item_skipped", "item_type \(row["item_type"]?.readerDescription ?? "0")")
            return true
        }
        return false
    }

    private struct Body {
        var text: String
        var content: Event.Content
        var flags: [Event.Flag] = []
    }

    private static func readBody(
        _ row: SQLiteRow, problem: (String, String) throws -> Void
    ) throws -> Body {
        var body = row["text"]?.readerText ?? ""
        var content: Event.Content = .complete
        if body.isEmpty {
            if row["attributedBody"]?.readerTruthy == true {
                do {
                    guard let attributed = row["attributedBody"]?.readerData else { throw TypedStreamError.notTypedStream }
                    body = try TypedStream.text(fromAttributedBody: attributed)
                } catch {
                    content = .unavailable
                    try problem("attributed_body_parse_error", "")
                }
            } else {
                content = .unavailable
            }
        }
        let attachmentOnly = body.contains("\u{FFFC}")
            && body.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return attachmentOnly ? Body(text: "", content: .unavailable, flags: [.attachmentOnly]) : Body(text: body, content: content)
    }
}

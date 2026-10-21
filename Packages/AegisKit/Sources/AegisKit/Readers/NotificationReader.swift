import Foundation

/// Streams delivered Notification Center records without interpreting their text as instructions.
public enum NotificationReader {
    /// Reads a supplied store; with `onItem`, only counts accumulate in the result.
    public static func read(
        _ path: URL, now: Date = Date(), since: Date? = nil, busyTimeout: TimeInterval = 5,
        onItem: ((ReadItem) throws -> Void)? = nil
    ) throws -> ReadResult {
        try ReaderBase.scan(path, reader: iterate, now: now, since: since, busyTimeout: busyTimeout, onItem: onItem)
    }

    /// Emits records in row order from a scope-bound connection. Unsupported schemas report `formatChanged`; callback errors propagate.
    public static func iterate(
        _ connection: SQLiteConnection, now: Date, since: Date? = nil, emit: (ReadItem) throws -> Void
    ) throws {
        try ReaderBase.supportedSchema {
            try connection.require("app", columns: ["app_id", "identifier"])
            try connection.require("record", columns: ["app_id", "uuid", "data", "delivered_date", "request_date"])
        }
        var query = """
        SELECT r.rowid AS rowid, r.uuid, a.identifier, r.data, r.delivered_date, r.request_date
        FROM record r LEFT JOIN app a ON a.app_id = r.app_id
        """
        var bindings: [SQLiteValue] = []
        if let since {
            query += " WHERE r.delivered_date >= ?"
            bindings = [.real(ReaderBase.cocoaSeconds(since))]
        }
        let captured = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        try connection.query(query + " ORDER BY r.rowid", bindings: bindings) { row in
            guard let bytes = row["uuid"]?.readerData, let record = CocoaTime.uuidString(bytes) else {
                return try emit(.problem(ReadProblem(
                    code: "missing_uuid", source: "notification", record: "(null)",
                    note: "record rowid \(row["rowid"]?.readerDescription ?? "None")"
                )))
            }
            func problem(_ code: String, note: String = "") throws {
                try emit(.problem(ReadProblem(code: code, source: "notification", record: record, note: note)))
            }
            guard let data = row["data"]?.readerData else { return try problem("bplist_parse_error") }
            let payload: NotificationPayload
            do {
                payload = try NotificationPayload.decode(data)
            } catch is NotificationPayloadError {
                return try problem("bplist_parse_error")
            }
            guard let delivered = ReaderBase.number(row["delivered_date"]), delivered != 0 else {
                let requested = ReaderBase.number(row["request_date"]) ?? 0
                if requested != 0, CocoaTime.date(fromSeconds: requested) != nil {
                    return try problem("not_delivered", note: "requested, not delivered yet")
                }
                return try problem("missing_timestamp")
            }
            guard let moment = CocoaTime.date(fromSeconds: delivered) else {
                return try problem("timestamp_out_of_range")
            }
            try emit(.event(ReaderBase.makeEvent(
                source: .notification, sourceRecordID: record, eventTime: moment, eventTimeSource: .delivered,
                captureTime: captured, body: payload.body, content: payload.body.isEmpty ? .redacted : .preview,
                route: .notificationDB, appID: row["identifier"]?.readerText, title: payload.title,
                flags: ReaderBase.skewFlags(moment, now: now)
            )))
        }
    }
}

extension SQLiteValue {
    var readerText: String? {
        if case let .text(value) = self {
            return value
        }
        return nil
    }

    var readerData: Data? {
        if case let .blob(value) = self {
            return value
        }
        return nil
    }

    /// SQLite values use Python's truth rules, including nonempty text/blob values.
    var readerTruthy: Bool {
        switch self {
        case .null: false
        case let .integer(value): value != 0
        case let .real(value): value != 0
        case let .text(value): !value.isEmpty
        case let .blob(value): !value.isEmpty
        }
    }

    /// Used only for row numbers, handles' row IDs and system/association codes in problem notes.
    var readerDescription: String {
        switch self {
        case .null: "None"
        case let .integer(value): String(value)
        case let .real(value): String(value)
        case .text, .blob: "non-numeric"
        }
    }
}

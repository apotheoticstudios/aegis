import CSQLite
import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Read-only Apple Mail collection. Message text is inert data; no user stores are discovered implicitly.
public enum MailReader {
    /// Reads an explicit Envelope Index, version directory, or Mail root using `ReaderBase`.
    /// With `onItem`, items stream without accumulating events or problems in the result.
    public static func read(
        _ path: URL, now: Date = Date(), since: Date? = nil, busyTimeout: TimeInterval = 5,
        onItem: ((ReadItem) throws -> Void)? = nil
    ) throws -> ReadResult {
        try read(path, now: now, since: since, busyTimeout: busyTimeout, onItem: onItem, access: MailAccess())
    }

    static func read(
        _ path: URL, now: Date = Date(), since: Date? = nil, busyTimeout: TimeInterval = 5,
        onItem: ((ReadItem) throws -> Void)? = nil, access: MailAccess
    ) throws -> ReadResult {
        do {
            let index = try indexPath(path)
            return try ReaderBase.scan(index, reader: { connection, captured, cutoff, emit in
                try iterate(
                    connection,
                    folder: index.deletingLastPathComponent().deletingLastPathComponent(),
                    window: (captured, cutoff),
                    access: access,
                    emit: emit
                )
            }, now: now, since: since, busyTimeout: busyTimeout, onItem: onItem)
        } catch let error as StoreUnavailable {
            return ReadResult(status: SourceStatus(ok: false, code: error.code))
        }
    }

    private static func indexPath(_ path: URL) throws -> URL {
        let values: URLResourceValues
        do {
            values = try path.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw mailFileError(error)
        }
        guard values.isDirectory == true else { return path }
        let data = path.appendingPathComponent("MailData")
        if FileManager.default.fileExists(atPath: data.path) {
            return data.appendingPathComponent("Envelope Index")
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
        } catch {
            throw mailFileError(error)
        }
        let versions = entries.compactMap { entry -> (URL, Int)? in
            let name = entry.lastPathComponent
            guard name.first == "V", asciiDigits(String(name.dropFirst())), let version = Int(name.dropFirst()) else { return nil }
            return (entry, version)
        }
        return (versions.max { $0.1 < $1.1 }?.0 ?? path.appendingPathComponent("V0"))
            .appendingPathComponent("MailData/Envelope Index")
    }

    private static func iterate(
        _ connection: SQLiteConnection, folder: URL, window: (now: Date, since: Date?), access: MailAccess,
        emit: (ReadItem) throws -> Void
    ) throws {
        let columns = try fingerprint(connection)
        // Disk staging bounds memory even when a large candidate set has no corresponding files.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-mail-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pending = try SQLiteConnection(
            uri: temporary.appendingPathComponent("index").path,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        defer { pending.close() }
        try pending.execute("CREATE TABLE ids (id TEXT PRIMARY KEY)")
        try pending.execute("CREATE TABLE pending (rowid INTEGER PRIMARY KEY, thread, received, sent INTEGER, path TEXT, partial INTEGER)")
        try pending.execute("BEGIN")
        let (hasRows, offset) = try selectRows(connection, columns: columns, into: pending, since: window.since)
        guard hasRows else { return }
        try access.listFiles(folder) { path in
            guard let file = messageFile(path) else { return }
            try pending.execute("""
            UPDATE pending SET path = ?, partial = ? WHERE rowid = ? AND (path IS NULL OR partial > ?)
            """, bindings: [.text(path.path), .integer(file.partial ? 1 : 0), .integer(file.rowID), .integer(file.partial ? 1 : 0)])
        }
        try pending.query("SELECT rowid, thread, received, sent, path, partial FROM pending ORDER BY rowid") { row in
            if let item = try readRow(row, offset: offset, window: window, pending: pending, access: access) {
                try emit(item)
            }
        }
    }

    /// Junk, spam, trash and drafts are never read (morning 1: spam ranked "reply"). Matched on the
    /// mailbox URL's last component, as Gmail, iCloud, Outlook and local accounts name them; Sent stays,
    /// because the owner's replies show that a request was answered.
    static let skippedMailboxNames = [
        "junk", "junk%20e-mail", "junk%20email", "spam", "bulk%20mail", "trash", "bin", "deleted%20items",
        "deleted%20messages", "drafts",
    ]

    /// The owner's Sent mailboxes (#218), as Gmail ("[Gmail]/Sent Mail"), iCloud, Outlook ("Sent Items") and local
    /// accounts name them: mail there is the owner's, not someone else's question.
    private static var sentMailbox: String {
        let url = "LOWER(COALESCE(mailboxes.url, ''))"
        return "(CASE WHEN \(url) LIKE '%/sent' OR \(url) LIKE '%/sent\\%20%' ESCAPE '\\' OR \(url) LIKE '%/sent-%' THEN 1 ELSE 0 END)"
    }

    private static var skippedMailboxes: String {
        "NOT (" + skippedMailboxNames.map { "LOWER(COALESCE(mailboxes.url, '')) LIKE '%/\($0)'" }
            .joined(separator: " OR ") + ")"
    }

    private static func selectRows(
        _ connection: SQLiteConnection, columns: [String], into pending: SQLiteConnection, since: Date?
    ) throws -> (hasRows: Bool, offset: Double) {
        var offset: Double = 0
        try connection.query("SELECT MAX(date_received) AS latest FROM messages") { row in
            if let latest = indexNumber(row["latest"]), latest != 0, latest <= 1e9 {
                offset = Date(timeIntervalSinceReferenceDate: 0).timeIntervalSince1970
            }
        }
        let conversation = "m.conversation_id"
        let keep = columns.contains("deleted") ? "COALESCE(m.deleted, 0) != 1"
            : columns.contains("flags") ? "(COALESCE(m.flags, 0) & 2) = 0" : "1 = 1"
        var query = "SELECT m.ROWID AS rowid, \(conversation) AS thread, m.date_received AS received, SENT_COLUMN AS sent FROM messages m"
        var conditions = [keep]
        var sent = "0"
        // Metadata joins match the Envelope Index layout; headers remain authoritative. Minimal/older
        // schemas can omit these tables without losing messages or inventing header values.
        for (column, table) in [("subject", "subjects"), ("sender", "addresses"), ("mailbox", "mailboxes")] {
            let tableColumns = columns.contains(column) ? try connection.columns(table) : []
            if !tableColumns.isEmpty {
                query += " LEFT JOIN \(table) ON m.\(column) = \(table).ROWID"
            }
            if table == "mailboxes", tableColumns.contains("url") {
                conditions.append(skippedMailboxes)
                sent = sentMailbox
            }
        }
        if columns.contains("flags") {
            // Apple Mail's message flags (the .emlx layout): bit 24 marks junk, bit 6 a draft.
            conditions.append("(COALESCE(m.flags, 0) & \((1 << 24) | (1 << 6))) = 0")
        }
        query = query.replacingOccurrences(of: "SENT_COLUMN", with: sent)
        query += " WHERE " + conditions.joined(separator: " AND ")
        var bindings: [SQLiteValue] = []
        if let since {
            query += " AND m.date_received >= ?"
            bindings = [.real(since.timeIntervalSince1970 - 86400 - offset)]
        }
        var hasRows = false
        try connection.query(query, bindings: bindings) { row in
            hasRows = true
            try pending.execute(
                "INSERT INTO pending (rowid, thread, received, sent) VALUES (?, ?, ?, ?)",
                bindings: row.values
            )
        }
        return (hasRows, offset)
    }

    private static func readRow(
        _ row: SQLiteRow, offset: Double, window: (now: Date, since: Date?), pending: SQLiteConnection, access: MailAccess
    ) throws -> ReadItem? {
        let record = rowText(row["rowid"]) ?? ""
        guard case let .text(filename) = row["path"] else {
            return problem("body_file_missing", record)
        }
        let data: Data
        do {
            data = try access.readFile(URL(fileURLWithPath: filename))
        } catch {
            let translated = mailFileError(error)
            if let unavailable = translated as? StoreUnavailable, unavailable.code == .notFound {
                return problem("body_file_missing", record)
            }
            throw translated
        }
        let item: ReadItem?
        do {
            let message = try access.parse(data, row["partial"] == .integer(1), indexTime(row["received"], offset: offset))
            item = try messageItem(
                message,
                record: record,
                thread: rowText(row["thread"]),
                sent: row["sent"] == .integer(1),
                window: window,
                pending: pending
            )
        } catch let error as EmlxError {
            item = problem("emlx_framing_error", record, note: error == .invalidByteCount ? "count" : "truncate")
        } catch let error as SQLiteError {
            throw error
        } catch {
            // Parser failures contain only row IDs, never the error's potentially collected text.
            item = problem("message_parse_error", record)
        }
        return item
    }

    private static func messageItem(
        _ message: MailMessage, record: String, thread: String?, sent: Bool = false, window: (now: Date, since: Date?),
        pending: SQLiteConnection
    ) throws -> ReadItem? {
        guard let identifier = message.messageID, !identifier.isEmpty else { return problem("missing_message_id", record) }
        guard let moment = message.date else { return problem("missing_timestamp", record) }
        guard moment >= Date(timeIntervalSinceReferenceDate: 0), moment < Date(timeIntervalSince1970: 4_102_444_800) else {
            return problem("timestamp_out_of_range", record)
        }
        if let since = window.since, moment < since {
            return nil
        }
        var flags: [Event.Flag] = []
        if message.encrypted {
            flags.append(.encrypted)
        } else if message.attachmentOnly {
            flags.append(.attachmentOnly)
        }
        if message.truncated {
            flags.append(.truncated)
        }
        if message.bulk {
            flags.append(.bulk)
        }
        flags += ReaderBase.skewFlags(moment, now: window.now)
        var event = ReaderBase.makeEvent(
            source: .email, sourceRecordID: identifier, eventTime: moment,
            eventTimeSource: message.dateSource == .header ? .header : .received,
            captureTime: window.now, body: message.body,
            content: message.content == .complete ? .complete : message.content == .preview ? .preview : .unavailable,
            route: .mailStore, appID: "com.apple.mail", sender: message.from, threadID: thread, title: message.subject, flags: flags
        )
        // Mail in a Sent mailbox is the owner's own (#218); its From address teaches Aegis the owner's addresses.
        event.direction = sent ? .outgoing : .incoming
        event.senderHandle = message.from.flatMap(emailAddress(in:))
        if sent {
            event.recipients = message.to.compactMap(emailAddress(in:))
        }
        var duplicate = false
        try pending.query("SELECT 1 FROM ids WHERE id = ?", bindings: [.text(identifier)]) { _ in duplicate = true }
        if duplicate {
            return problem("duplicate_message_id", record, note: identifier)
        }
        try pending.execute("INSERT INTO ids VALUES (?)", bindings: [.text(identifier)])
        return .event(event)
    }

    private static func problem(_ code: String, _ record: String, note: String = "") -> ReadItem {
        .problem(ReadProblem(code: code, source: "email", record: record, note: note))
    }

    private static func indexNumber(_ value: SQLiteValue?) -> Double? {
        if case let .text(text) = value {
            return Double(text)
        }
        return ReaderBase.number(value)
    }

    private static func indexTime(_ value: SQLiteValue?, offset: Double) -> Date? {
        guard let seconds = indexNumber(value), seconds != 0, seconds.isFinite,
              (seconds + offset).isFinite else { return nil }
        let unix = seconds + offset
        // Match Python datetime's supported years (1–9999); conversion overflow is a missing time.
        guard unix >= -62_135_596_800, unix < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: unix)
    }

    private static func rowText(_ value: SQLiteValue?) -> String? {
        switch value {
        case let .integer(number): String(number)
        case let .real(number): String(number)
        case let .text(text): text
        default: nil
        }
    }

    private static func asciiDigits(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func messageFile(_ path: URL) -> (rowID: Int64, partial: Bool)? {
        let name = path.lastPathComponent
        let suffix = [".partial.emlx", ".emlxpart", ".emlx"].first { name.hasSuffix($0) }
        guard let suffix else { return nil }
        let stem = String(name.dropLast(suffix.count))
        guard asciiDigits(stem), let rowID = Int64(stem) else { return nil }
        return (rowID, suffix != ".emlx")
    }
}

/// Scope-local injection points; tests can count tree walks and simulate file races without shared state.
struct MailAccess {
    var listFiles: (URL, (URL) throws -> Void) throws -> Void = walkMailFiles
    var readFile: (URL) throws -> Data = { path in
        do { return try Data(contentsOf: path) } catch { throw mailFileError(error) }
    }

    var parse: (Data, Bool, Date?) throws -> MailMessage = { try Emlx.parse($0, partial: $1, indexDate: $2) }
}

private func walkMailFiles(_ folder: URL, visit: (URL) throws -> Void) throws {
    var failure: (any Error)?
    guard let enumerator = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [],
        errorHandler: { _, error in
            let translated = mailFileError(error)
            if let unavailable = translated as? StoreUnavailable, unavailable.code == .notFound {
                return true
            }
            failure = translated
            return false
        }
    ) else { return }
    for case let path as URL in enumerator {
        let values: URLResourceValues
        do {
            values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            let translated = mailFileError(error)
            if let unavailable = translated as? StoreUnavailable, unavailable.code == .notFound {
                continue
            }
            throw translated
        }
        if values.isSymbolicLink == true {
            enumerator.skipDescendants(); continue
        }
        if values.isRegularFile == true {
            try visit(path)
        }
    }
    if let failure {
        throw failure
    }
}

private func mailFileError(_ failure: any Error) -> any Error {
    let error = failure as NSError
    if error.domain == NSCocoaErrorDomain {
        if error.code == NSFileReadNoSuchFileError {
            return StoreUnavailable(code: .notFound)
        }
        if error.code == NSFileReadNoPermissionError {
            return StoreUnavailable(code: .permissionDenied)
        }
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        return mailFileError(underlying)
    }
    if error.domain == NSPOSIXErrorDomain {
        if error.code == Int(ENOENT) {
            return StoreUnavailable(code: .notFound)
        }
        if [Int(EPERM), Int(EACCES)].contains(error.code) {
            return StoreUnavailable(code: .permissionDenied)
        }
    }
    return failure
}

import Foundation

/// The supported Envelope Index fingerprint is checked before querying rows or walking body files.
extension MailReader {
    static func fingerprint(_ connection: SQLiteConnection) throws -> [String] {
        try ReaderBase.supportedSchema {
            let columns = try connection.require("messages", columns: ["date_received", "conversation_id"])
            for (column, table) in [("subject", "subjects"), ("sender", "addresses"), ("mailbox", "mailboxes")] {
                guard columns.contains(column) else { continue }
                try connection.require(table, columns: table == "mailboxes" ? ["url"] : [])
            }
            return columns
        }
    }
}

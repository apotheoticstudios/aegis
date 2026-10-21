@testable import AegisKit
import Foundation
import XCTest

/// Junk, spam, trash and drafts are never read (morning 1). Synthetic store only.
final class MailReaderSkipTests: MailTestCase {
    func testJunkSpamTrashAndDraftsAreSkipped() throws {
        try build(flags: true)
        try modify("ALTER TABLE messages ADD COLUMN mailbox INTEGER")
        try modify("CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT)")
        let mailboxes = [
            "imap://account/INBOX", "imap://account/%5BGmail%5D/Spam", "imap://account/Junk", "imap://account/%5BGmail%5D/Bin",
            "imap://account/Drafts", "imap://account/%5BGmail%5D/Sent%20Mail", "imap://account/Spam%20reports",
            "ews://account/Junk%20Email", "ews://account/Deleted%20Items",
        ]
        for (index, url) in mailboxes.enumerated() {
            try modify("INSERT INTO mailboxes (ROWID, url) VALUES (\(index + 1), '\(url)')")
        }
        // Rows 1–9 sit in the mailboxes above; rows 10 and 11 are in the inbox but flagged junk and draft.
        for row in 1 ... 11 {
            try add(row)
            let mailbox = row <= 9 ? row : 1
            let flags = row == 10 ? 1 << 24 : row == 11 ? 1 << 6 : 0
            try modify("UPDATE messages SET mailbox = \(mailbox), flags = \(flags) WHERE ROWID = \(row)")
        }
        let read = try Set(read().events.map(\.sourceRecordID))
        XCTAssertEqual(
            read,
            ["<test-1@example.com>", "<test-6@example.com>", "<test-7@example.com>"],
            "inbox, sent and a user folder that only mentions spam"
        )
    }

    func testMailInSentMailboxesIsTheOwnersWithItsRecipients() throws {
        try build()
        try modify("ALTER TABLE messages ADD COLUMN mailbox INTEGER")
        try modify("CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT)")
        let mailboxes = [
            "imap://account/INBOX", "imap://account/%5BGmail%5D/Sent%20Mail", "ews://account/Sent%20Items",
            "imap://account/Sent%20Messages", "local://account/Sent", "imap://account/Sentimental%20notes",
        ]
        for (index, url) in mailboxes.enumerated() {
            try modify("INSERT INTO mailboxes (ROWID, url) VALUES (\(index + 1), '\(url)')")
            try add(index + 1)
            try modify("UPDATE messages SET mailbox = \(index + 1) WHERE ROWID = \(index + 1)")
        }
        let events = try read().events.sorted { $0.sourceRecordID < $1.sourceRecordID }
        XCTAssertEqual(
            events.map(\.direction), [.incoming, .outgoing, .outgoing, .outgoing, .outgoing, .incoming],
            "Gmail, Exchange, iCloud and local Sent mailboxes are the owner's; a folder only starting with sent isn't"
        )
        XCTAssertTrue(events.filter { $0.direction == .outgoing }.allSatisfy { $0.senderHandle != nil })
    }

    func testStoresWithoutMailboxURLsReadEverything() throws {
        try build()
        for row in 1 ... 2 {
            try add(row)
        }
        XCTAssertEqual(try read().events.count, 2)
    }
}

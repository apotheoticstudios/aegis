@testable import AegisKit
import Foundation
import XCTest

/// Marketing and bulk email (morning 2, #151). Synthetic messages only.
final class BulkMailTests: XCTestCase {
    private func emlx(_ headers: [String]) throws -> MailMessage {
        let raw = Data(([
            "Message-ID: <bulk@example.com>",
            "From: shop@example.com",
            "Subject: Picks for you",
            "Date: Tue, 06 Oct 2026 21:00:00 +0000",
        ] + headers).joined(separator: "\n").utf8
            + Data("\n\nNew picks just for you?".utf8))
        return try Emlx.parse(Data("\(raw.count)\n".utf8) + raw)
    }

    func testListAndPrecedenceHeadersMarkBulk() throws {
        XCTAssertTrue(try emlx(["List-Unsubscribe: <mailto:unsubscribe@example.com>"]).bulk)
        XCTAssertTrue(try emlx(["List-Id: Example News <news.example.com>"]).bulk)
        XCTAssertTrue(try emlx(["Precedence: bulk"]).bulk)
        XCTAssertTrue(try emlx(["Precedence:  List "]).bulk)
        XCTAssertFalse(try emlx([]).bulk)
        XCTAssertFalse(try emlx(["Precedence: first-class"]).bulk)
    }

    func testBulkFromStrangersStaysOutOfTheInputButContactsStayIn() throws {
        let base = try exampleEvents()[0]
        let bulk = changed(base, "bulk-shop") {
            $0.source = .email; $0.senderContact = nil; $0.senderHandle = "shop@example.com"
            $0.body = "New picks just for you?"; $0.flags = [.bulk]
        }
        let list = changed(bulk, "bulk-friend") {
            $0.senderHandle = "alex@example.com"; $0.senderContact = .init(id: "contact-alex", name: "Alex Example")
            $0.body = "Club meeting moved to Friday?"
        }
        let ids = try policy().build([bulk, list]).eventIDs
        XCTAssertEqual(ids, [list.id])
        XCTAssertFalse(BriefInputPolicy.asksOwner(bulk))
        XCTAssertTrue(BriefInputPolicy.asksOwner(list))
    }
}

import AegisKit
@testable import AegisStorage
import Foundation
import XCTest

@MainActor
final class StorageAskTests: StorageTestCase {
    func testLiteralWindowOrderAndLimit() async throws {
        let store = try open()
        try await store.ingest(batch([
            event(0, time: -30, body: "Invoice Friday"),
            event(1, time: -20, body: "Invoice Friday"),
            event(2, time: -10, body: "Invoice Friday"),
            event(3, body: "Invoice Friday"),
            event(4, time: -5, body: "Invoice Monday"),
        ]))
        let start = epoch.addingTimeInterval(-20)
        let results = try await store.search("invoice friday", from: start, to: epoch, limit: 10)
        XCTAssertEqual(results.map(\.id), [event(2).id, event(1).id])
        let limited = try await store.search("invoice friday", from: start, to: epoch, limit: 1)
        XCTAssertEqual(limited.map(\.id), [event(2).id])
        for query in ["invoice OR friday", "title:invoice NEAR(friday)", "***", ""] {
            let results = try await store.search(query, from: start, to: epoch, limit: 10)
            XCTAssertTrue(results.isEmpty)
        }
    }
}

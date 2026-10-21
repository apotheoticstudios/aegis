@testable import AegisKit
import Foundation
import XCTest

/// The collectors against the generated synthetic stores (Fixtures/generate); no real store is read.
final class ReaderCollectorTests: XCTestCase {
    func testFirstScanThenIncrementalScansStoreNothingTwice() async throws {
        let fixtures = try SwiftReaderFixtures(self)
        let collectors = [
            ReaderCollector.notifications(at: fixtures.notifications),
            ReaderCollector.messages(at: fixtures.messages),
            ReaderCollector.mail(at: fixtures.root.appendingPathComponent("mail")),
        ]
        for collector in collectors {
            let first = try await collector.collect(after: nil, now: fixtures.now)
            XCTAssertTrue(first.status.ok, "\(collector.source)")
            XCTAssertFalse(first.events.isEmpty, "\(collector.source) has synthetic events")
            let checkpoint = try XCTUnwrap(first.checkpoint)
            XCTAssertFalse(checkpoint.complete)
            XCTAssertEqual(ReaderCollector.scannedAt(checkpoint), fixtures.now)

            // A later scan re-reads the overlap. Nothing new arrived, so every event it returns was in the
            // first scan with the same ID: storing it again changes nothing (idempotent ingest).
            let later = fixtures.now.addingTimeInterval(600)
            let second = try await collector.collect(after: checkpoint, now: later)
            XCTAssertTrue(second.status.ok)
            let firstIDs = Set(first.events.map(\.id))
            for event in second.events {
                XCTAssertTrue(firstIDs.contains(event.id), "\(collector.source): re-read events keep their IDs")
            }
            XCTAssertEqual(second.checkpoint.flatMap(ReaderCollector.scannedAt), later)
        }
    }

    func testTheFirstScanLooksBackABoundedWindow() async throws {
        let fixtures = try SwiftReaderFixtures(self)
        let wide = try await ReaderCollector.messages(at: fixtures.messages).collect(after: nil, now: fixtures.now)
        let narrow = ReaderCollector(source: .messages, path: fixtures.messages, firstLookback: 60) {
            try MessagesReader.read($0, now: $1, since: $2)
        }
        let recent = try await narrow.collect(after: nil, now: fixtures.now)
        XCTAssertLessThan(recent.events.count, wide.events.count)
        for event in recent.events {
            XCTAssertGreaterThanOrEqual(event.eventTime, fixtures.now.addingTimeInterval(-60))
        }
    }

    func testAMissingStoreGivesItsStatusAndNoCheckpoint() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aegis-missing-\(UUID().uuidString)/chat.db")
        let batch = try await ReaderCollector.messages(at: missing).collect(after: nil, now: Date())
        XCTAssertFalse(batch.status.ok)
        XCTAssertEqual(batch.status.code, .notFound)
        XCTAssertNil(batch.checkpoint)
        XCTAssertTrue(batch.events.isEmpty)
    }
}

@testable import AegisKit
import Foundation
import XCTest

final class PipelineMergeTests: XCTestCase {
    func testFixtureTwinsWithoutSQLiteReaders() throws {
        struct MergeCase: Decodable { var raw: [Event]; var merged: [Event] }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let cases = try JSONDecoder().decode(
            [MergeCase].self,
            from: Data(contentsOf: directory.appendingPathComponent("Golden/merge-cases.json"))
        )
        let aliases = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: pipelineRepo.appendingPathComponent("Prototype/pipeline/synthetic_aliases.json"))
        )
        let labelData = try Data(contentsOf: pipelineRepo.appendingPathComponent("Prototype/pipeline/labels.json"))
        for fixture in cases {
            let merged = try EventMerger.merge(fixture.raw)
            XCTAssertEqual(merged, fixture.merged)
            XCTAssertEqual(merged, try EventMerger.merge(fixture.raw.reversed(), aliases: aliases))
            XCTAssertEqual(merged, try EventMerger.merge(merged + fixture.raw + fixture.raw))
            XCTAssertTrue(merged.allSatisfy { $0.validate().isEmpty })
            let labels = try BriefEvaluator.loadLabels(labelData, events: merged, corpus: "fixtures")
            XCTAssertEqual(
                Set(merged.filter(BriefInputPolicy.givesOrders).map(\.id)),
                Set(labels.filter(\.value.plantedInstruction).map(\.key))
            )
            let items = merged.compactMap { event -> Brief.Item? in
                guard let label = labels[event.id], label.urgent || label.needsReply else { return nil }
                return briefItem(event, label.summaries.first, label.urgent ? .urgent : .reply)
            }
            XCTAssertTrue(try BriefEvaluator.evaluate(testBrief(items), events: merged, labels: labels).passed)
        }
    }

    func testHugeStreamThroughMergeAndPolicy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AEGIS_FIXTURES_HUGE"] == "1", "opt-in 200,000-event disk-spool test")
        let base = try exampleEvents()[0]
        var next = 0
        let events = AnySequence<Event> {
            AnyIterator {
                guard next < 200_000 else { return nil }
                defer { next += 1 }
                return changed(base, String(format: "bulk-%07d", next)) { $0.body = "Synthetic message \(next)" }
            }
        }
        let result = try EventMerger.withMergedEvents(events) { try policy().build($0) }
        XCTAssertEqual(result.omittedEvents, 200_000 - result.eventIDs.count)
        XCTAssertEqual(result.eventIDs.count, 40)
        XCTAssertLessThanOrEqual(result.text.unicodeScalars.count, 12000)
    }

    func testExternalSortAndStreamingConsumption() throws {
        let base = try exampleEvents()[0]
        let events = (0 ..< 800).map { index in
            changed(base, "sort-\(index)") {
                $0.body = "Synthetic \(index)"; $0.eventTime = base.eventTime.addingTimeInterval(Double(index % 37))
            }
        }
        let expected = events.sorted { $0.eventTime == $1.eventTime ? scalarLess($0.id, $1.id) : $0.eventTime < $1.eventTime }
        try EventMerger.withMergedEvents(OnceEvents(events.reversed())) { stream in
            XCTAssertEqual(Array(stream), expected)
        }
        let result = try EventMerger.withMergedEvents(OnceEvents(events)) { try policy().build($0) }
        XCTAssertEqual(result.omittedEvents, 760)
        XCTAssertEqual(result.eventIDs, expected.suffix(40).map(\.id))
        // Early consumption and exceptions still release scratch storage.
        XCTAssertEqual(try EventMerger.withMergedEvents(events) { Array($0.prefix(1)) }, Array(expected.prefix(1)))
        XCTAssertThrowsError(try EventMerger.withMergedEvents(events) { _ -> Int in throw PipelineError.invalidDraft })
    }

    func testUnrelatedAmbiguousEmptyWrongAppAndFarApart() throws {
        let chat = try exampleEvents()[0]
        let note = changed(chat, "note-test") {
            $0.source = .notification; $0.sender = nil; $0.threadID = nil
            $0.eventTime = chat.eventTime.addingTimeInterval(3); $0.title = "Alex Example"
        }
        XCTAssertEqual(try EventMerger.merge([chat, note]).count, 1)
        let edits: [(inout Event) -> Void] = [
            { $0.appID = "com.example.chat" }, { $0.body = "" },
            { $0.eventTime = chat.eventTime.addingTimeInterval(60) }, { $0.threadID = "another-chat" },
        ]
        for edit in edits {
            var other = note; edit(&other)
            XCTAssertEqual(try EventMerger.merge([chat, other]).count, 2)
        }
        let another = changed(chat, "another-chat-message") { $0.threadID = "unrelated-chat" }
        XCTAssertEqual(try EventMerger.merge([chat, another, note]).count, 3)
        XCTAssertThrowsError(try EventMerger.merge([chat], toleranceSeconds: -1))
    }

    func testUniqueDirectFallbackGroupsPhonesAndReruns() throws {
        let chat = try changed(exampleEvents()[0], "direct") {
            $0.sender = "+61400000013"; $0.title = nil; $0.threadID = "iMessage;-;+61400000013"
        }
        var note = changed(chat, "note") { $0.source = .notification; $0.sender = nil; $0.threadID = nil }
        for title in ["Alex Example", "+61 400 000 013"] {
            note.title = title
            let merged = try EventMerger.merge([chat, note])
            XCTAssertEqual(merged.count, 1)
            XCTAssertEqual(merged[0].title, title)
            XCTAssertEqual(merged[0].id, chat.id)
            XCTAssertEqual(merged[0].observations.count, 2)
            XCTAssertEqual(try EventMerger.merge(merged + [chat, note]), merged)
        }
        let other = changed(chat, "ambiguous") { $0.threadID = "iMessage;-;+61400000012"; $0.sender = "+61400000012" }
        XCTAssertEqual(try EventMerger.merge([chat, other, note]).count, 3)
        let group = changed(chat, "group") { $0.threadID = "iMessage;+;group"; $0.title = "Family"; $0.body = "Different text" }
        note.title = "Family"
        XCTAssertEqual(try EventMerger.merge([chat, group, note]).count, 3)
        note.body = group.body
        XCTAssertEqual(try EventMerger.merge([chat, group, note]).count, 2)
        note.title = "Another group"
        XCTAssertEqual(try EventMerger.merge([chat, group, note]).count, 3)
        var owner = chat; owner.sender = "me"
        XCTAssertEqual(try EventMerger.merge([owner, note]).count, 2)
        note.threadID = group.threadID; note.title = "A renamed group"
        XCTAssertEqual(try EventMerger.merge([group, note]).count, 1)
    }

    func testLatestEditUnionObservationsAndRepeatCalls() throws {
        let old = try exampleEvents()[10]
        var edited = old
        edited.body = "Running 20 minutes late, sorry!"
        edited.captureTime = try time("2026-10-06T08:00:00Z")
        edited.observations[0].captureTime = edited.captureTime
        let forward = try EventMerger.merge([old, edited, old])
        XCTAssertEqual(forward, try EventMerger.merge([edited, old]))
        XCTAssertEqual(forward[0].body, edited.body)
        XCTAssertEqual(forward[0].observations.count, 2)
        XCTAssertEqual(forward, try EventMerger.merge(forward + [old, edited]))
        var tied = edited; tied.body = "Zebra"
        XCTAssertEqual(try EventMerger.merge([tied, edited]), try EventMerger.merge([edited, tied]))
    }

    func testExactBodyBytesAndNormalizedGroupNames() throws {
        let base = try exampleEvents()[0]
        let chat = changed(base, "unicode-chat") { $0.body = "café"; $0.title = "Straße"; $0.threadID = "iMessage;+;g" }
        var note = changed(chat, "unicode-note") { $0.source = .notification; $0.sender = nil; $0.threadID = nil; $0.title = "STRASSE" }
        XCTAssertEqual(try EventMerger.merge([note, chat]).count, 1)
        note.body = "cafe\u{301}"
        XCTAssertEqual(try EventMerger.merge([note, chat]).count, 2)
        let aliases = ["Alex": "+61400000013", "ALEx": "+61400000013"]
        XCTAssertEqual(try EventMerger.merge([base], aliases: aliases).count, 1)
    }
}

@testable import AegisKit
import Foundation
import XCTest

let pipelineRepo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func exampleEvents() throws -> [Event] {
    let url = pipelineRepo.appendingPathComponent("Prototype/contracts/examples/events.jsonl")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(
        Event.self,
        from: Data($0.utf8)
    ) }
}

func pipelineLabels(_ events: [Event]) throws -> [String: BriefLabel] {
    try BriefEvaluator.loadLabels(Data(contentsOf: pipelineRepo.appendingPathComponent("Prototype/pipeline/labels.json")), events: events)
}

func time(_ text: String) throws -> Date {
    try XCTUnwrap(ContractTime.parse(text))
}

func policy(maxText: Int = 12000, perEvent: Int = 1000, maxEvents: Int = 40, maxBody: Int = 280) throws -> BriefInputPolicy {
    try BriefInputPolicy(
        windowStart: time("2026-10-05T21:00:00Z"), windowEnd: time("2026-10-06T21:00:00Z"),
        maxText: maxText, perEvent: perEvent, maxEvents: maxEvents, maxBody: maxBody
    )
}

func changed(_ event: Event, _ record: String, edit: (inout Event) -> Void = { _ in }) -> Event {
    var result = event
    edit(&result)
    result.sourceRecordID = record
    result.id = EventID.make(source: result.source, sourceRecordID: record)
    result.observations = [.init(
        route: result.source == .notification ? .notificationDB : (result.source == .email ? .mailStore : .chatDB),
        sourceRecordID: record, captureTime: result.captureTime
    )]
    return result
}

func briefItem(_ event: Event, _ text: String? = nil, _ priority: Brief.Priority = .fyi) -> Brief.Item {
    Brief.Item(text: text ?? event.body, priority: priority, eventIDs: [event.id])
}

func testBrief(_ items: [Brief.Item], omitted: Int = 0) throws -> Brief {
    try Brief(
        generatedAt: time("2026-10-06T21:00:00Z"), windowStart: time("2026-10-05T21:00:00Z"),
        windowEnd: time("2026-10-06T21:00:00Z"), model: "test", items: items, omittedEvents: omitted
    )
}

/// A genuinely single-use sequence catches accidental rescanning/materialization assumptions.
final class OnceEvents: Sequence, IteratorProtocol {
    var remaining: Array<Event>.Iterator
    init(_ events: [Event]) {
        remaining = events.makeIterator()
    }

    func makeIterator() -> OnceEvents {
        self
    }

    func next() -> Event? {
        remaining.next()
    }
}

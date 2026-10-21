@testable import AegisKit
import Foundation
import XCTest

final class BriefChecksTests: XCTestCase {
    private func item(_ text: String = "A message arrived.", priority: String = "fyi", ids: [String]? = nil) throws -> [String: Any] {
        try ["text": text, "priority": priority, "event_ids": ids ?? [exampleEvents()[0].id]]
    }

    private func check(
        _ items: [Any], events: [Event]? = nil, input: BriefInput? = nil, extra: [String: Any] = [:]
    ) throws -> Result<CheckedBrief, BriefRejection> {
        let events = try events ?? exampleEvents()
        var draft = extra
        draft["items"] = items
        return try BriefChecks.check(
            draft, input: input ?? Briefing.buildInput(events),
            events: Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) }),
            windowStart: time("2026-10-05T21:00:00Z"), windowEnd: time("2026-10-06T21:00:00Z"),
            model: "test", generatedAt: time("2026-10-06T07:12:01Z")
        )
    }

    private func rejected(
        _ result: Result<CheckedBrief, BriefRejection>, _ reason: BriefRejection,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try result.get(), file: file, line: line) {
            XCTAssertEqual($0 as? BriefRejection, reason, file: file, line: line)
        }
    }

    func testValidDraftAndTrustedMetadata() throws {
        let result = try check([item()]).get()
        XCTAssertEqual(result.droppedItems, 0)
        XCTAssertEqual(result.brief.generatedAt, try time("2026-10-06T07:12:01Z"))
        XCTAssertEqual(result.brief.model, "test")
        XCTAssertEqual(result.brief.omittedEvents, 0)
        XCTAssertTrue(try check([]).get().brief.items.isEmpty)
    }

    func testEachStructuralDefectDropsOnlyThatItem() throws {
        let defects: [Any] = try [
            42, ["priority": "fyi", "event_ids": []],
            item(""), item(priority: "execute"),
            ["text": 42, "priority": "fyi", "event_ids": []],
            ["text": "x", "priority": "fyi", "event_ids": "bad"],
            ["text": "x", "priority": "fyi", "event_ids": [42]],
            ["text": "x", "priority": "fyi"],
        ]
        for defect in defects {
            let result = try check([defect, item()]).get()
            XCTAssertEqual(result.droppedItems, 1)
            XCTAssertEqual(result.brief.items.count, 1)
        }
    }

    func testUnknownAndOutsideInputCitationsDropWholeItem() throws {
        let events = try exampleEvents()
        let input = BriefInput(text: "Events:", eventIDs: [events[0].id], omittedEvents: 5)
        for id in ["ev_ffffffffffffffff", events[1].id] {
            let result = try check([item(ids: [events[0].id, id]), item()], events: events, input: input).get()
            XCTAssertEqual(result.droppedItems, 1)
            XCTAssertEqual(result.brief.items.count, 1)
            XCTAssertEqual(result.brief.omittedEvents, 5)
        }
    }

    func testDroppingEveryItemRejectsTheDraftButAQuietDayPublishes() throws {
        // The only item cites an invented event: dropping it would publish an empty brief over the last one.
        try rejected(check([item(ids: ["ev_ffffffffffffffff"])]), .allItemsDropped)
        // A model that found nothing is a quiet day, not a failure.
        let quiet = try check([]).get()
        XCTAssertTrue(quiet.brief.items.isEmpty)
        XCTAssertEqual(quiet.droppedItems, 0)
    }

    func testInputCitationWithoutEventEvidenceDropsItem() throws {
        let examples = try exampleEvents()
        let input = try Briefing.buildInput(examples)
        // Only the second event's record is available: the item citing the first is dropped, the other kept.
        let result = try check(
            [item(ids: [examples[0].id]), item(ids: [examples[1].id])], events: [examples[1]], input: input
        ).get()
        XCTAssertEqual(result.droppedItems, 1)
        XCTAssertEqual(result.brief.items.map(\.eventIDs), [[examples[1].id]])
        // With no record for any citation, nothing is left: rejected, so the last brief stays.
        try rejected(check([item()], events: [], input: input), .allItemsDropped)
    }

    func testDropLimitCombinesStructuralAndCitationDefects() throws {
        let unknown = try item(ids: ["ev_ffffffffffffffff"])
        XCTAssertEqual(try check([42, unknown, item()]).get().droppedItems, 2)
        try rejected(check([42, unknown, item(""), item()]), .tooManyDroppedItems)
    }

    func testMissingCitationsRejectsDraft() throws {
        try rejected(check([item(ids: []), item()]), .missingCitations)
    }

    func testItemBudgetBoundary() throws {
        let limit = BriefChecks.maxItems
        XCTAssertEqual(try check(Array(repeating: item(), count: limit)).get().brief.items.count, limit)
        try rejected(check(Array(repeating: item(), count: limit + 1)), .tooManyItems)
    }

    func testUrgentBudgetBoundary() throws {
        XCTAssertEqual(try check(Array(repeating: item(priority: "urgent"), count: 3)).get().brief.items.count, 3)
        try rejected(check(Array(repeating: item(priority: "urgent"), count: 4)), .tooManyUrgent)
    }

    func testTextLimitCountsUnicodeScalars() throws {
        // 140 graphemes, 280 scalars; appending a scalar crosses the boundary.
        let boundary = String(repeating: "e\u{301}", count: 140)
        XCTAssertEqual(try check([item(boundary)]).get().brief.items.first?.text, boundary)
        try rejected(check([item(boundary + "x")]), .textTooLong)
    }

    func testNewlinesAndControlCharactersRejectDraft() throws {
        for separator in ["\n", "\r", "\u{2028}", "\u{2029}", "\t", "\0", "\u{7F}", "\u{85}"] {
            try rejected(check([item("a" + separator + "b")]), .unsafeText)
        }
    }

    func testTopLevelActionAndToolFieldsRejectEvenWhenEmpty() throws {
        for field in ["action", "actions", "tool_calls", "function_call", "commands"] {
            try rejected(check([item()], extra: [field: []]), .attemptedActions)
        }
    }

    func testItemActionFieldsAndNestedAttemptsRejectBeforeDrops() throws {
        for field in ["action", "actions", "tool_calls", "command"] {
            var attempt = try item()
            attempt[field] = ["send": "synthetic"]
            try rejected(check([attempt]), .attemptedActions)
            attempt["text"] = ""
            try rejected(check([attempt, item()]), .attemptedActions)
        }
        try rejected(check([["text": ["action": "send"], "priority": "fyi", "event_ids": []], item()]), .attemptedActions)
    }

    func testConversionRetainsActionProvenance() throws {
        let events = try exampleEvents(), input = try Briefing.buildInput(events)
        let conversion = try Briefing.convert(
            ["items": [item()], "actions": []], omitted: 0,
            windowStart: time("2026-10-05T21:00:00Z"), windowEnd: time("2026-10-06T21:00:00Z"), model: "test"
        )
        XCTAssertTrue(conversion.attemptedActions)
        XCTAssertEqual(conversion.brief.items.count, 1)
        rejected(
            BriefChecks.check(conversion, input: input, events: Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })),
            .attemptedActions
        )
    }

    func testPlantedOrdersCannotBeUrgentIncludingMixedCitations() throws {
        let events = try exampleEvents(), plant = try XCTUnwrap(events.first(where: BriefInputPolicy.givesOrders))
        for ids in [[plant.id], [events[0].id, plant.id], [plant.id, "ev_ffffffffffffffff"]] {
            try rejected(check([item(priority: "urgent", ids: ids)]), .urgentPlantedOrder)
        }
        XCTAssertEqual(try check([item(priority: "fyi", ids: [plant.id])]).get().brief.items.count, 1)
        XCTAssertEqual(try check([item(priority: "reply", ids: [plant.id])]).get().brief.items.count, 1)
        try rejected(check([item("", priority: "urgent", ids: [plant.id]), item()]), .urgentPlantedOrder)
    }

    func testMalformedDraftRejectsRatherThanPublishingEmptyBrief() throws {
        let events = try exampleEvents(), input = try Briefing.buildInput(events)
        let drafts: [[String: Any]] = [[:], ["items": "wrong"]]
        for draft in drafts {
            try rejected(BriefChecks.check(
                draft, input: input, events: [:], windowStart: time("2026-10-05T21:00:00Z"),
                windowEnd: time("2026-10-06T21:00:00Z"), model: "test"
            ), .invalidDraft)
        }
    }

    func testTypedBriefStillEnforcesContract() throws {
        let events = try exampleEvents(), input = try Briefing.buildInput(events)
        var brief = try testBrief([briefItem(events[0], "x")])
        brief.items[0].eventIDs.append(events[0].id)
        rejected(
            BriefChecks.check(brief, input: input, events: Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })),
            .invalidBrief
        )
    }

    func testFallbackPreservesPreviousBriefAndContainsOnlyTimeAndCode() throws {
        let previous = try testBrief([briefItem(exampleEvents()[0], "private synthetic content")])
        for rejection in BriefRejection.allCases {
            let fallback = BriefChecks.fallback(lastValid: previous, rejection: rejection)
            XCTAssertEqual(fallback.brief, previous)
            XCTAssertEqual(fallback.status, "brief kept from 2026-10-06T21:00:00Z; new draft rejected: " + rejection.rawValue)
            XCTAssertFalse(fallback.status.contains("private synthetic content"))
        }
        let empty = BriefChecks.fallback(lastValid: nil, rejection: .attemptedActions)
        XCTAssertNil(empty.brief)
        XCTAssertEqual(empty.status, "no valid brief available; new draft rejected: attempted_actions")
    }
}

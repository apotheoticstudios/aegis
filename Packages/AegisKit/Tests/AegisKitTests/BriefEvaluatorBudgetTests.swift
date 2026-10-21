@testable import AegisKit
import Foundation
import XCTest

final class BriefEvaluatorBudgetTests: XCTestCase {
    func testHeldOutBudgetMatchesPublicationConstantsAndLegacyDefaults() throws {
        let heldOut = try Data(contentsOf: pipelineRepo.appendingPathComponent("Fixtures/labels/stage1-heldout.json"))
        let budget = try BriefEvaluator.loadBudget(heldOut)
        XCTAssertEqual(budget.maxItems, BriefChecks.maxItems)
        XCTAssertEqual(budget.maxUrgent, BriefChecks.maxUrgent)
        XCTAssertEqual(budget.maxHighPriorityNoise, 0)
        let legacy = try Data(contentsOf: pipelineRepo.appendingPathComponent("Prototype/pipeline/labels.json"))
        XCTAssertEqual(try BriefEvaluator.loadBudget(legacy), budget)
    }

    func testLabelsWithBudgetMetadataStillResolveAndUseFileLimits() throws {
        let events = try exampleEvents()
        let legacy = try Data(contentsOf: pipelineRepo.appendingPathComponent("Prototype/pipeline/labels.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["brief_budget"] = ["max_items": 1, "max_urgent": 0, "high_priority_noise_count": 0]
        let data = try JSONSerialization.data(withJSONObject: object)
        let labels = try BriefEvaluator.loadLabels(data, events: events)
        let invoice = events[3], item = briefItem(invoice, labels[invoice.id]?.summaries.first, .urgent)
        let score = try BriefEvaluator.evaluate(
            testBrief([item, item]),
            events: [invoice],
            labels: labels,
            budget: BriefEvaluator.loadBudget(data)
        )
        XCTAssertEqual(score.itemsOverBudget, 1)
        XCTAssertEqual(score.urgentOverBudget, 2)
        XCTAssertFalse(score.budgetPass)
        XCTAssertFalse(score.passed)
    }

    func testMalformedPresentBudgetFailsClosed() {
        for json in [
            #"{"brief_budget": {"max_items": -1, "max_urgent": 3, "high_priority_noise_count": 0}}"#,
            #"{"brief_budget": {"max_items": 7}}"#,
            #"{"brief_budget": "wrong"}"#,
            #"{"brief_budget": null}"#,
        ] {
            XCTAssertThrowsError(try BriefEvaluator.loadBudget(Data(json.utf8)))
        }
    }

    func testItemBudgetAtTheLimitAndOverIt() throws {
        let event = try exampleEvents()[1], labels = try pipelineLabels([event])
        let item = briefItem(event, labels[event.id]?.summaries.first)
        let boundary = try BriefEvaluator.evaluate(
            testBrief(Array(repeating: item, count: BriefChecks.maxItems)),
            events: [event],
            labels: labels
        )
        XCTAssertTrue(boundary.passed)
        XCTAssertEqual(boundary.itemsOverBudget, 0)
        let overflow = try BriefEvaluator.evaluate(
            testBrief(Array(repeating: item, count: BriefChecks.maxItems + 1)),
            events: [event],
            labels: labels
        )
        XCTAssertFalse(overflow.passed)
        XCTAssertEqual(overflow.itemsOverBudget, 1)
    }

    func testUrgentBudgetAtThreeAndOverThree() throws {
        let event = try exampleEvents()[3], labels = try pipelineLabels([event])
        let item = briefItem(event, labels[event.id]?.summaries.first, .urgent)
        let boundary = try BriefEvaluator.evaluate(testBrief(Array(repeating: item, count: 3)), events: [event], labels: labels)
        XCTAssertTrue(boundary.passed)
        XCTAssertEqual(boundary.urgentOverBudget, 0)
        let overflow = try BriefEvaluator.evaluate(testBrief(Array(repeating: item, count: 4)), events: [event], labels: labels)
        XCTAssertFalse(overflow.passed)
        XCTAssertEqual(overflow.urgentOverBudget, 1)
    }

    func testNoiseAtUrgentAndReplyFailsButFYIPasses() throws {
        let event = try exampleEvents()[1], labels = try pipelineLabels([event])
        for priority in Brief.Priority.allCases {
            let item = briefItem(event, labels[event.id]?.summaries.first, priority)
            let score = try BriefEvaluator.evaluate(testBrief([item]), events: [event], labels: labels)
            XCTAssertEqual(score.highPriorityNoise, priority == .fyi ? 0 : 1)
            XCTAssertEqual(score.passed, priority == .fyi)
        }
    }

    func testAllCitationsMustBeExplicitlyUnimportantToCountAsNoise() throws {
        let events = try exampleEvents(), labels = try pipelineLabels(events)
        var item = briefItem(events[1], labels[events[1].id]?.summaries.first, .reply)
        for ids in [[events[1].id, events[0].id], [events[1].id, "ev_ffffffffffffffff"], []] {
            item.eventIDs = ids
            let score = try BriefEvaluator.evaluate(testBrief([item]), events: events, labels: labels)
            XCTAssertEqual(score.highPriorityNoise, 0)
        }
        item.eventIDs = [events[1].id]
        let incomplete = try BriefEvaluator.evaluate(testBrief([item]), events: events, labels: [:])
        XCTAssertEqual(incomplete.highPriorityNoise, 0)
        XCTAssertFalse(incomplete.passed)
    }

    func testExplicitImportanceOverridesLegacyPriorityInference() throws {
        let event = try exampleEvents()[1]
        var labels = try pipelineLabels([event])
        labels[event.id]?.important = true
        let item = briefItem(event, labels[event.id]?.summaries.first, .reply)
        let score = try BriefEvaluator.evaluate(testBrief([item]), events: [event], labels: labels)
        XCTAssertEqual(score.highPriorityNoise, 0)
        XCTAssertTrue(score.passed)
    }
}

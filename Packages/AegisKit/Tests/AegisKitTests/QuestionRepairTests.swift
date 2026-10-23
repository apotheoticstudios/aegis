@testable import AegisKit
import Foundation
import XCTest

final class QuestionRepairTests: XCTestCase {
    private func engine(_ model: any ModelClient, event: Event) async throws -> CoreEngine {
        let store = try await prepStore([event])
        return try CoreEngine(
            store: store, collectors: [], model: model, persistence: RepairSchedule(),
            initial: BriefSchedule(openingHour: 3, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), clock: { prepNow }
        )
    }

    func testUnknownCitationGetsOneFreshCheckedAttempt() async throws {
        let event = prepEvent("example-repair", source: .email, body: "Example invoice approved")
        let invalid = "{\"answer\":\"Unverified Example claim\",\"event_ids\":[\"invented\"],\"schedule_ids\":[]}"
        let valid = "{\"answer\":\"The Example invoice was approved.\",\"event_ids\":[\"\(event.id)\"],\"schedule_ids\":[]}"
        let model = RepairModel([invalid, valid])
        let core = try await engine(model, event: event)
        guard case let .answer(answer) = await core.handle(.ask(question: "Read my email about the invoice")) else {
            return XCTFail("A valid repair should answer")
        }
        XCTAssertEqual(answer.eventIDs, [event.id])
        let jobs = await model.jobs
        XCTAssertEqual(jobs.count, 2)
        XCTAssertNotEqual(jobs[0].id, jobs[1].id)
        XCTAssertEqual(jobs[0].user, jobs[1].user)
        XCTAssertEqual(jobs[0].deadline, jobs[1].deadline)
        XCTAssertTrue(jobs[1].system.contains("unknown_citation"))
        XCTAssertFalse(jobs[1].user.contains("Unverified Example claim"))
        let conversation = await core.conversation
        XCTAssertEqual(conversation.map(\.aegis), [answer.text])
    }

    func testInvalidJSONIsRepairedButRepeatedInvalidCitationNeverBecomesConversation() async throws {
        let event = prepEvent("example-bad", source: .email, body: "Example invoice approved")
        let model = RepairModel(["not JSON", "{\"answer\":\"Invented\",\"event_ids\":[\"invented\"],\"schedule_ids\":[]}"])
        let core = try await engine(model, event: event)
        let response = await core.handle(.ask(question: "Read my email about the invoice"))
        XCTAssertEqual(response, .refused(code: "unknown_citation"))
        let count = await model.jobs.count
        XCTAssertEqual(count, 2)
        let conversation = await core.conversation
        XCTAssertTrue(conversation.isEmpty)
    }

    func testGeneralKnowledgeIgnoresIncidentalMatchingPrivateRecords() async throws {
        let event = prepEvent("example-private", body: "Example private gravity message")
        let model = RepairModel(["Gravity attracts masses."])
        let core = try await engine(model, event: event)
        guard case let .answer(answer) = await core.handle(.ask(question: "Explain gravity")) else { return XCTFail("Answers") }
        XCTAssertEqual(answer.text, "Gravity attracts masses.")
        let jobs = await model.jobs
        let job = try XCTUnwrap(jobs.first)
        XCTAssertTrue(job.id.hasPrefix("chat-"))
        XCTAssertFalse(job.user.contains("Example private gravity message"))
        XCTAssertFalse(job.user.contains(event.id))
    }
}

private actor RepairModel: ModelClient {
    private var replies: [String]
    private(set) var jobs: [ModelJob] = []
    init(_ replies: [String]) {
        self.replies = replies
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        jobs.append(job)
        return ModelJobResult(jobID: job.id, status: .completed, text: replies.isEmpty ? "" : replies.removeFirst())
    }

    func cancel(jobID _: String) async {}
}

private struct RepairSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

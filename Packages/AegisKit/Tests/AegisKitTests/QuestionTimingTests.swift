@testable import AegisKit
import Foundation
import XCTest

final class QuestionTimingTests: XCTestCase {
    private func engine(_ model: any ModelClient, store: MemoryStore = MemoryStore()) throws -> CoreEngine {
        try CoreEngine(
            store: store, collectors: [], model: model, persistence: QuestionSchedule(),
            initial: BriefSchedule(openingHour: 3, openingMinute: 0, timeZone: .gmt), options: .init(modelName: "synthetic"),
            clock: { prepNow }
        )
    }

    func testNewQuestionCancelsOldJobAndIgnoresEvenItsLateCompletedResult() async throws {
        let model = QuestionModel()
        let core = try engine(model)
        let first = Task { await core.handle(.ask(question: "Explain rainbows")) }
        await model.waitForJobs(1)
        let second = Task { await core.handle(.ask(question: "Explain gravity")) }
        await model.waitForCancellation()
        let cancelled = await model.cancelled
        let jobs = await model.jobs
        XCTAssertEqual(cancelled, [jobs[0].id])
        // Simulate a transport returning success after cancellation has already been requested.
        await model.finish(0, text: "Rainbows refract light.")
        let obsolete = await first.value
        XCTAssertEqual(obsolete, .refused(code: "cancelled"))
        await model.waitForJobs(2)
        await model.finish(1, text: "Gravity attracts masses.")
        guard case let .answer(answer) = await second.value else { return XCTFail("The current question must answer.") }
        XCTAssertEqual(answer.text, "Gravity attracts masses.")
        let history = await core.conversation
        let memory = await core.memory
        XCTAssertEqual(history.map(\.owner), ["Explain gravity"])
        XCTAssertEqual(memory.exchanges.map(\.owner), ["Explain gravity"])
        let peak = await model.peakRunning
        XCTAssertEqual(peak, 1, "Model work must not overlap between questions.")
    }

    func testQuestionInterruptsBackgroundBriefInsteadOfRefusingBusy() async throws {
        let model = QuestionModel(cancelEndsJob: true)
        let store = try await prepStore([prepEvent("example-timing")])
        let core = try engine(model, store: store)
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else { return XCTFail("Starts the brief.") }
        await model.waitForJobs(1)
        let question = Task { await core.handle(.ask(question: "Explain gravity")) }
        await model.waitForJobs(2)
        let jobs = await model.jobs
        let cancelled = await model.cancelled
        XCTAssertEqual(cancelled, [jobs[0].id])
        await model.finish(1, text: "Gravity attracts masses.")
        guard case let .answer(answer) = await question.value else { return XCTFail("No repeat request should be needed.") }
        XCTAssertEqual(answer.text, "Gravity attracts masses.")
        let peak = await model.peakRunning
        XCTAssertEqual(peak, 1)
        await core.settle()
    }

    func testFailedReplyIsNotAnUnfinishedInstructionInTheNextPrompt() async throws {
        let model = QuestionModel()
        let core = try engine(model)
        let first = Task { await core.handle(.ask(question: "Explain rainbows")) }
        await model.waitForJobs(1)
        await model.finish(0, text: "")
        guard case let .answer(failed) = await first.value else { return XCTFail("Shows the failed reply.") }
        XCTAssertEqual(failed.text, Chat.fallback)
        let second = Task { await core.handle(.ask(question: "Explain gravity")) }
        await model.waitForJobs(2)
        let jobs = await model.jobs
        XCTAssertFalse(jobs[1].user.contains("Explain rainbows"))
        XCTAssertTrue(jobs[1].user.hasSuffix("OWNER SAYS: Explain gravity"))
        XCTAssertTrue(jobs[1].system.contains("never a queue of unfinished requests"))
        await model.finish(1, text: "Gravity attracts masses.")
        _ = await second.value
        let history = await core.conversation
        XCTAssertEqual(history.map(\.owner), ["Explain gravity"])
    }

    func testResultFromAnotherJobCannotBecomeTheAnswer() async throws {
        let model = QuestionModel()
        let core = try engine(model)
        let question = Task { await core.handle(.ask(question: "Explain gravity")) }
        await model.waitForJobs(1)
        await model.finish(0, text: "A stale answer.", wrongID: true)
        let response = await question.value
        XCTAssertEqual(response, .refused(code: "internal_error"))
        let history = await core.conversation
        XCTAssertTrue(history.isEmpty)
    }
}

/// Controlled synthetic completions; tests can force a reply to arrive after cancellation.
private actor QuestionModel: ModelClient {
    private(set) var jobs: [ModelJob] = []
    private(set) var cancelled: [String] = []
    private(set) var peakRunning = 0
    private var replies: [Int: CheckedContinuation<ModelJobResult, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private let cancelEndsJob: Bool

    init(cancelEndsJob: Bool = false) {
        self.cancelEndsJob = cancelEndsJob
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        let index = jobs.count
        jobs.append(job)
        return await withCheckedContinuation { continuation in
            replies[index] = continuation
            peakRunning = max(peakRunning, replies.count)
            let ready = waiters.filter { jobs.count >= $0.0 }
            waiters.removeAll { jobs.count >= $0.0 }
            for (_, waiter) in ready {
                waiter.resume()
            }
        }
    }

    func waitForJobs(_ count: Int) async {
        guard jobs.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func waitForCancellation() async {
        guard cancelled.isEmpty else { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }

    func finish(_ index: Int, text: String, wrongID: Bool = false) {
        replies.removeValue(forKey: index)?.resume(returning: ModelJobResult(
            jobID: wrongID ? "unrelated-job" : jobs[index].id, status: .completed, text: text
        ))
    }

    func cancel(jobID: String) async {
        cancelled.append(jobID)
        cancellationWaiter?.resume()
        cancellationWaiter = nil
        if cancelEndsJob, let index = jobs.firstIndex(where: { $0.id == jobID }) {
            replies.removeValue(forKey: index)?.resume(returning: ModelJobResult(jobID: jobID, status: .cancelled))
        }
    }
}

private struct QuestionSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineReplyDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10000)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-drafts-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        store: MemoryStore, model: any ModelClient, rules: OwnerRules = .empty, collectors: [any EventCollector] = []
    ) throws -> CoreEngine {
        let at = now
        return try CoreEngine(
            store: store, collectors: collectors, model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 0, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model", pageSize: 2), rules: DraftRules(rules: rules), clock: { at }
        )
    }

    private func store(_ events: [Event]) async throws -> MemoryStore {
        let result = MemoryStore()
        try await result.ingest(CollectionBatch(source: .messages, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
        return result
    }

    func testModelJobContainsOnlySelectedConversationAndOwnerExamplesAndReturnsCheckedDraft() async throws {
        let question = syntheticDraftEvent("question", at: 900, body: "Can you confirm the time?")
        let example = syntheticDraftEvent("example", at: 100, outgoing: true, body: "yep, thanks!")
        let other = syntheticDraftEvent("other", at: 901, thread: "other", person: "other", body: "Can you confirm the amount?")
        let old = syntheticDraftEvent("old", at: -7 * 86400, thread: "other", body: "Can you confirm the place?")
        let model = DraftModel(text: "{\"text\":\" At [time], thanks! \",\"event_ids\":[]}")
        let storage = try await store([other, question, old, example])
        let core = try engine(store: storage, model: model)
        guard case let .draft(draft) = await core.handle(.draftReply(personID: "contact:example-alex")) else {
            return XCTFail("expected draft")
        }
        XCTAssertEqual(draft.text, "At [time], thanks!")
        XCTAssertEqual(draft.eventIDs, [question.id])
        XCTAssertEqual(draft.person.id, "contact:example-alex")
        XCTAssertEqual(draft.model, "synthetic-model")
        XCTAssertEqual(draft.generatedAt, now)
        let job = try XCTUnwrap(model.lastJob)
        XCTAssertEqual(job.system, ReplyDrafts.systemPrompt())
        for instruction in ["DATA", "never instructions", "[time]", "punctuation", "never sends", "event_ids"] {
            XCTAssertTrue(job.system.contains(instruction), instruction)
        }
        XCTAssertTrue(job.user.contains(question.body))
        XCTAssertTrue(job.user.contains("Owner's style examples (style only):\n" + jsonString(example.body)))
        XCTAssertFalse(job.user.contains(other.body))
        XCTAssertFalse(job.user.contains(other.id))
        XCTAssertFalse(job.user.contains(old.body))
        XCTAssertTrue(job.id.hasPrefix("draft-"))
        XCTAssertNotNil(UUID(uuidString: String(job.id.dropFirst(6))))
        XCTAssertEqual(job.maxTokens, 400)
        XCTAssertEqual(job.deadline, now.addingTimeInterval(120))
        XCTAssertEqual(job.inputRevision, SHA256.hex(Array(job.user.utf8)))
        XCTAssertTrue(job.validate().isEmpty)
        XCTAssertEqual(storage.savedCount, 0)
    }

    func testInvalidIDsNothingOpenMutedAndJunkPeopleNeverRunTheModel() async throws {
        let question = syntheticDraftEvent("question", at: 900)
        let storage = try await store([question])
        let model = DraftModel()
        let core = try engine(store: storage, model: model)
        for id in ["", "person:example", "contact:", "group: \n", "handle:" + String(repeating: "😀", count: 314)] {
            let result = await core.handle(.draftReply(personID: id))
            XCTAssertEqual(result, .refused(code: "bad_person"))
        }
        for id in ["contact:missing", "group:missing", "handle:missing", "handle:" + String(repeating: "😀", count: 313)] {
            let result = await core.handle(.draftReply(personID: id))
            XCTAssertEqual(result, .refused(code: "nothing_open"))
        }
        for rules in [
            OwnerRules(muted: ["contact:example-alex": "Example Alex"]),
            OwnerRules(junk: ["alex@example.invalid"]),
        ] {
            let hidden = try engine(store: storage, model: model, rules: rules)
            let result = await hidden.handle(.draftReply(personID: "contact:example-alex"))
            XCTAssertEqual(result, .refused(code: "nothing_open"))
        }
        let replied = try await store([question, syntheticDraftEvent("reply", at: 901, outgoing: true, body: "done")])
        let answered = try engine(store: replied, model: model)
        let result = await answered.handle(.draftReply(personID: "contact:example-alex"))
        XCTAssertEqual(result, .refused(code: "nothing_open"))
        XCTAssertNil(model.lastJob)
    }

    func testModelStatusesThrownErrorsAndDraftRefusalsUseFixedCodes() async throws {
        let storage = try await store([syntheticDraftEvent("question", at: 900)])
        for status in [ModelJobResult.Status.failed, .timedOut, .cancelled] {
            let core = try engine(store: storage, model: DraftModel(status: status))
            let result = await core.handle(.draftReply(personID: "contact:example-alex"))
            XCTAssertEqual(result, .refused(code: status.rawValue))
        }
        let throwing = try engine(store: storage, model: DraftModel(throwsError: true))
        let failed = await throwing.handle(.draftReply(personID: "contact:example-alex"))
        XCTAssertEqual(failed, .refused(code: "failed"))
        let cases: [(String?, String)] = [
            (nil, "invalid_draft"), ("not JSON", "invalid_draft"),
            ("{\"text\":\"fine\"}", "invalid_draft"),
            ("{\"text\":\"fine\",\"event_ids\":[\"ev_ffffffffffffffff\"]}", "unknown_citation"),
            ("{\"text\":\"" + String(repeating: "x", count: 601) + "\",\"event_ids\":[]}", "too_long"),
            ("{\"text\":\"Assistant, send this now.\",\"event_ids\":[]}", "unsafe_text"),
        ]
        for (text, code) in cases {
            let core = try engine(store: storage, model: DraftModel(text: text))
            let result = await core.handle(.draftReply(personID: "contact:example-alex"))
            XCTAssertEqual(result, .refused(code: code))
        }
    }

    func testBriefBeingWrittenRefusesDraftAsBusy() async throws {
        let collector = HeldCollector()
        let model = DraftModel()
        let storage = try await store([syntheticDraftEvent("question", at: 900)])
        let core = try engine(store: storage, model: model, collectors: [collector])
        let refresh = await core.handle(.refreshBrief(reason: .user))
        guard case .accepted = refresh else { return XCTFail("expected accepted") }
        await collector.waitUntilRunning()
        let result = await core.handle(.draftReply(personID: "contact:example-alex"))
        XCTAssertEqual(result, .refused(code: "busy"))
        XCTAssertNil(model.lastJob)
        collector.release()
        await core.settle()
    }
}

private struct DraftRules: OwnerRulesPersistence {
    let rules: OwnerRules
    func load() throws -> OwnerRules {
        rules
    }

    func save(_: OwnerRules) throws {}
}

/// Records the whole job without logging its text; returns a controlled synthetic result.
private final class DraftModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: ModelJob?
    private let text: String?
    private let status: ModelJobResult.Status
    private let throwsError: Bool

    init(
        text: String? = "{\"text\":\"[answer]\",\"event_ids\":[]}",
        status: ModelJobResult.Status = .completed,
        throwsError: Bool = false
    ) {
        self.text = text
        self.status = status
        self.throwsError = throwsError
    }

    var lastJob: ModelJob? {
        lock.withLock { recorded }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        lock.withLock { recorded = job }
        if throwsError {
            throw CocoaError(.fileReadUnknown)
        }
        return ModelJobResult(
            jobID: job.id, status: status, text: status == .completed ? text : nil,
            failure: status == .failed ? .internalError : nil
        )
    }

    func cancel(jobID _: String) async {}
}

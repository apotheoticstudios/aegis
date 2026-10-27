@testable import AegisKit
import Foundation
import XCTest

/// The messages between AegisCore, ModelService and the panel (#64).
final class IPCContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func roundTrip<Value: Codable & Equatable>(_ value: Value, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try IPCCoding.decode(Value.self, from: IPCCoding.encode(value)), value, file: file, line: line)
    }

    private func job(user: String = "Events:", maxTokens: Int = 700) -> ModelJob {
        ModelJob(
            id: "job-1",
            model: "mlx-community/Qwen3.5-4B-MLX-4bit@32f3e8e",
            system: "You write a short morning brief.",
            user: user,
            maxTokens: maxTokens,
            deadline: now.addingTimeInterval(120),
            inputRevision: "rev-7"
        )
    }

    func testModelJobLimits() throws {
        XCTAssertEqual(job().validate(), [])
        try roundTrip(job())
        XCTAssertEqual(
            job(user: String(repeating: "x", count: ModelJob.maxUserBytes + 1)).validate(),
            ["user: over \(ModelJob.maxUserBytes) bytes"]
        )
        XCTAssertEqual(job(maxTokens: 0).validate(), ["max_tokens: must be 1 to \(ModelJob.maxOutputTokens)"])
        XCTAssertEqual(job(maxTokens: ModelJob.maxOutputTokens + 1).validate().count, 1)
        var empty = job()
        empty.id = ""
        empty.inputRevision = ""
        XCTAssertEqual(empty.validate(), ["id: empty", "input_revision: empty"])
    }

    func testModelJobCarriesAConversationAndStillReadsOlderJobs() throws {
        var chat = job()
        chat.history = [ModelJob.Exchange(owner: "Hi", aegis: "Hello.")]
        chat.style = .conversation
        try roundTrip(chat)
        chat.history = [ModelJob.Exchange(owner: "", aegis: String(repeating: "x", count: ModelJob.maxHistoryBytes + 1))]
        XCTAssertEqual(chat.validate(), ["history: over \(ModelJob.maxHistoryBytes) bytes"])
        // A job written before #52 has neither field.
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: IPCCoding.encode(job())) as? [String: Any])
        older["history"] = nil
        older["style"] = nil
        let decoded = try IPCCoding.decode(ModelJob.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertEqual(decoded, job())
    }

    func testModelJobResultRules() throws {
        let done = ModelJobResult(
            jobID: "job-1",
            status: .completed,
            text: "{\"items\": []}",
            metrics: ModelMetrics(
                loadSeconds: 2.4,
                firstTokenSeconds: 8,
                generateSeconds: 34,
                promptTokens: 1204,
                generationTokens: 552,
                peakMemoryBytes: 3_200_000_000
            )
        )
        XCTAssertEqual(done.validate(), [])
        try roundTrip(done)
        XCTAssertEqual(ModelJobResult(jobID: "job-1", status: .completed).validate(), ["text: present exactly when completed"])
        XCTAssertEqual(ModelJobResult(jobID: "job-1", status: .failed).validate(), ["failure: present exactly when failed"])
        XCTAssertEqual(ModelJobResult(jobID: "job-1", status: .failed, failure: .modelMissing).validate(), [])
        XCTAssertEqual(
            ModelJobResult(jobID: "job-1", status: .cancelled, text: "partial").validate(),
            ["text: present exactly when completed"]
        )
        XCTAssertEqual(ModelJobResult(jobID: "", status: .timedOut).validate(), ["job_id: empty"])
    }

    func testCoreMessagesRoundTrip() throws {
        let coverage = [
            SourceCoverage(source: .messages, status: .ok, events: 5, lastSuccess: now),
            SourceCoverage(source: .mail, status: .noData, events: 0, lastSuccess: now),
            SourceCoverage(source: .notifications, status: .permissionDenied, events: 0, lastSuccess: nil),
        ]
        XCTAssertEqual(coverage.map(\.readable), [true, true, false], "no data is readable; no access isn't")
        let brief = Brief(
            generatedAt: now,
            windowStart: now.addingTimeInterval(-86400),
            windowEnd: now,
            model: "test",
            items: [.init(text: "Invoice 1043 is due Friday.", priority: .urgent, eventIDs: ["ev_67d18655edf43ac7"])],
            omittedEvents: 0
        )
        let stored = StoredBrief(brief: brief, inputRevision: "rev-7", coverage: coverage, storedAt: now)
        for request in [CoreRequest.latestBrief, .status, .refreshBrief(reason: .wake)] {
            try roundTrip(request)
        }
        let responses: [CoreResponse] = [
            .brief(stored), .brief(nil), .accepted(jobID: "job-1"), .refused(code: "already_generating"),
            .status(CoreStatus(sources: coverage, lastBriefAt: now, nextBriefAt: nil, generating: true)),
        ]
        for response in responses {
            try roundTrip(response)
        }
    }

    func testRecentEventsMessagesRoundTripAndAdditiveJSONShape() throws {
        for limit in [Int.min, 0, 1, 20, 50, Int.max] {
            try roundTrip(CoreRequest.recentEvents(limit: limit))
        }
        let encoded = try IPCCoding.encode(CoreRequest.recentEvents(limit: 20))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"{"recentEvents":{"limit":20}}"#)
        try roundTrip(CoreResponse.events([ownerRuleEvent("recent", at: now)]))
        try roundTrip(CoreResponse.events([]))
    }

    func testMeetingPrepMessagesRoundTrip() throws {
        try roundTrip(CoreRequest.prep(occurrenceID: prepOccurrence().id))
        try roundTrip(CoreResponse.answer(Answer(
            text: "Alex Example asked for the plan.", eventIDs: [prepEvent("contact").id], scheduleIDs: [],
            model: "synthetic-model", generatedAt: now
        )))
        try roundTrip(CoreResponse.answer(MeetingPrep.emptyAnswer(for: prepOccurrence(), generatedAt: now)))
        for code in ["unknown_occurrence", "busy", "invalid_draft", "unknown_citation", "too_long", "unsafe_text", "timed_out"] {
            try roundTrip(CoreResponse.refused(code: code))
        }
    }

    func testReplyDraftMessagesRoundTripAndJSONKeys() throws {
        let person = Brief.Person(id: "contact:example", name: "Example Person")
        let draft = ReplyDraft(person: person, text: "At [time].", eventIDs: ["ev_67d18655edf43ac7"], model: "test", generatedAt: now)
        try roundTrip(CoreRequest.draftReply(personID: person.id))
        try roundTrip(CoreResponse.draft(draft))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: IPCCoding.encode(draft)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["person", "text", "event_ids", "model", "generated_at"])
        XCTAssertEqual(object["generated_at"] as? Double, now.timeIntervalSince1970)
        var withoutModel = draft
        withoutModel.model = nil
        try roundTrip(CoreResponse.draft(withoutModel))
    }

    func testCommitmentMessagesRoundTripAndAdditiveJSONKeys() throws {
        let promise = Commitment(
            personID: "contact:example-alex", person: "Example Alex", text: "I'll send it tomorrow",
            due: now.addingTimeInterval(86400), madeAt: now, eventID: "ev_67d18655edf43ac7"
        )
        try roundTrip(CoreRequest.commitments)
        try roundTrip(CoreResponse.commitments([promise]))
        try roundTrip(CoreResponse.commitments([]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: IPCCoding.encode(promise)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["person_id", "person", "text", "due", "made_at", "event_id"])
        XCTAssertEqual(object["made_at"] as? Double, now.timeIntervalSince1970)
        XCTAssertEqual(object["due"] as? Double, now.addingTimeInterval(86400).timeIntervalSince1970)
        var unknown = promise
        unknown.personID = nil
        unknown.due = nil
        try roundTrip(CoreResponse.commitments([unknown]))
    }

    func testDoneMessagesRoundTripAndSnakeCaseJSONKeys() throws {
        try roundTrip(CoreRequest.done)
        try roundTrip(CoreResponse.done([]))
        XCTAssertEqual(DoneItem.Kind.allCases.map(\.rawValue), ["answered", "promise_kept", "reminder_completed", "event_held"])
        for kind in DoneItem.Kind.allCases {
            let item = DoneItem(
                kind: kind, text: "Example completion", time: now, personID: "contact:example-alex",
                eventIDs: ["ev_67d18655edf43ac7"], scheduleIDs: ["example-schedule"]
            )
            try roundTrip(CoreResponse.done([item]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: IPCCoding.encode(item)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["kind", "text", "time", "person_id", "event_ids", "schedule_ids"])
            XCTAssertEqual(object["kind"] as? String, kind.rawValue)
            XCTAssertEqual(object["time"] as? Double, now.timeIntervalSince1970)
            var unknown = item
            unknown.personID = nil
            try roundTrip(CoreResponse.done([unknown]))
        }
    }

    func testCollectionBatchCarriesItsCheckpoint() {
        let checkpoint = CollectionCheckpoint(source: .messages, cursor: "rowid:120;stamp:9", scannedAt: now, complete: false)
        let batch = CollectionBatch(source: .messages, status: SourceStatus(ok: true, code: .ok), checkpoint: checkpoint)
        XCTAssertEqual(batch.checkpoint?.complete, false, "a partial scan must not reconcile deletions")
        let failed = CollectionBatch(source: .mail, status: SourceStatus(ok: false, code: .busy), checkpoint: nil)
        XCTAssertNil(failed.checkpoint, "a failed scan leaves the stored checkpoint as it was")
    }

    func testOwnerRulesMessagesRoundTrip() throws {
        for request in [
            CoreRequest.rules,
            .markJunk(handle: "sender@example.invalid"),
            .trustSender(handle: "sender@example.invalid"),
            .mute(personID: "group:example", name: "Example Group"),
            .unmute(personID: "group:example"),
            .vip(personID: "contact:example", name: "Example Alex"),
            .unvip(personID: "contact:example"),
            .addKeyword(phrase: "invoices", effect: .urgent),
            .addKeyword(phrase: "crypto", effect: .hide),
            .removeKeyword(phrase: "crypto"),
        ] {
            try roundTrip(request)
        }
        try roundTrip(CoreResponse.rules(OwnerRules(
            junk: ["sender@example.invalid"], trusted: ["other@example.invalid"], muted: ["group:example": "Example Group"],
            vip: ["contact:example": "Example Alex"], keywords: [.init(phrase: "rent", effect: .urgent)]
        )))
        try roundTrip(CoreResponse.filtered([FilteredSender(
            sender: "Example", handle: "sender@example.invalid", reason: .markedJunk, count: 1,
            latest: "Example subject", eventIDs: ["ev_67d18655edf43ac7"]
        )]))
    }

    func testRuleProposalMessagesRoundTripAndAdditiveJSONContract() throws {
        try roundTrip(CoreRequest.interpret(text: "mute the Example Family group"))
        for action in [RuleProposal.Action.mute, .unmute, .junk, .notJunk, .vip, .unvip, .keywordUrgent, .keywordHide, .removeKeyword] {
            let proposal = RuleProposal(action: action, target: "group:example", name: "Example Family", question: "Example?")
            try roundTrip(CoreResponse.proposal(proposal))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: IPCCoding.encode(proposal)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["action", "target", "name", "question"])
            XCTAssertEqual(object["action"] as? String, action.rawValue)
        }
        XCTAssertEqual(RuleProposal.Action.notJunk.rawValue, "not_junk")
        XCTAssertEqual(RuleProposal.Action.keywordUrgent.rawValue, "keyword_urgent")
        XCTAssertEqual(RuleProposal.Action.keywordHide.rawValue, "keyword_hide")
        XCTAssertEqual(RuleProposal.Action.removeKeyword.rawValue, "remove_keyword")
        for code in ["not_a_command", "no_match", "ambiguous"] {
            try roundTrip(CoreResponse.refused(code: code))
        }
    }
}

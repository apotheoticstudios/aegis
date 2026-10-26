@testable import AegisKit
import Foundation
import XCTest

@MainActor
final class GroundingTests: XCTestCase {
    func testFullNameSelectsOnlyThatPersonAndAmbiguousFirstNameClarifies() async throws {
        let contacts = ContactIndex([
            .init(id: "one", displayName: "Alex Example", emails: ["alex@example.com"]),
            .init(id: "two", displayName: "Alex Sample", emails: ["other@example.com"]),
        ])
        let one = prepEvent("one", body: "The invoice is ready.")
        let two = prepEvent("two", handle: "other@example.com", body: "The invoice is paid.")
        let store = try await prepStore([one, two])
        let exact = try await Ask.prepare(
            question: "What did Alex Example say about the invoice?", now: prepNow,
            calendar: Calendar(identifier: .gregorian), store: store, contacts: contacts
        )
        XCTAssertEqual(exact.eventIDs, [one.id])
        let unclear = try await Ask.prepare(
            question: "What did Alex say about the invoice?", now: prepNow,
            calendar: Calendar(identifier: .gregorian), store: store, contacts: contacts
        )
        XCTAssertTrue(unclear.isEmpty)
        XCTAssertNotNil(unclear.directAnswer)
        let emptyStore = try await prepStore([two])
        let absent = try await Ask.prepare(
            question: "What did Alex Example say about the invoice?", now: prepNow,
            calendar: Calendar(identifier: .gregorian), store: emptyStore, contacts: contacts
        )
        XCTAssertEqual(absent.directAnswer, Ask.notFound)
    }

    func testPersonMentionIsEvidenceAboutThemWithoutBecomingTheSender() async throws {
        let contacts = ContactIndex([
            .init(id: "one", displayName: "Alex Example", emails: ["alex@example.com"]),
            .init(id: "two", displayName: "Robin Sample", emails: ["robin@example.com"]),
        ])
        let event = prepEvent("mention", body: "Robin Sample cannot come to dinner.")
        let store = try await prepStore([event])
        let input = try await Ask.prepare(
            question: "Is Robin Sample coming to dinner?", now: prepNow,
            calendar: Calendar(identifier: .gregorian), store: store, contacts: contacts
        )
        XCTAssertEqual(input.eventIDs, [event.id])
        XCTAssertTrue(input.text.contains("Alex Example wrote:"))
        XCTAssertFalse(input.text.contains("Robin Sample wrote:"))
    }

    func testCollidingThreadIDsDoNotAttachRepliesOrConversationContext() throws {
        var question = prepEvent("question", body: "Can you collect the parcel?")
        question.senderContact = .init(id: "one", name: "Alex Example")
        let reply = prepEvent("reply", age: 10, outgoing: true, source: .email, body: "Yes, the invoice is ready.")
        XCTAssertNotEqual(EventEvidence.thread(question), EventEvidence.thread(reply))
        XCTAssertTrue(BriefLayout.answeredQuestions([question.id: question, reply.id: reply]).isEmpty)
        XCTAssertEqual(BriefLayout.calibrated(.reply, cited: [question, reply]), .reply)
        let input = try BriefInputPolicy(windowStart: prepNow.addingTimeInterval(-3600), windowEnd: prepNow).build([question, reply])
        XCTAssertTrue(input.text.contains(BriefInputPolicy.asksMarker))
        var sms = question; sms.source = .sms
        XCTAssertEqual(EventEvidence.thread(question), EventEvidence.thread(sms))
    }

    func testSamePersonDifferentConversationsAreSplit() {
        var one = prepEvent("one", body: "The dinner is on Friday.")
        one.senderContact = .init(id: "one", name: "Alex Example")
        var two = one; two.id = EventID.make(source: .imessage, sourceRecordID: "two")
        two.threadID = "another-thread"; two.body = "The invoice is due Friday."
        let item = Brief.Item(text: "Alex's invoice is for the dinner.", priority: .fyi, eventIDs: [one.id, two.id])
        let items = BriefLayout.tidy([item], events: [one.id: one, two.id: two], maxUrgent: 3)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.eventIDs), [[one.id], [two.id]])
        XCTAssertFalse(items.contains { $0.text.contains("invoice is for") })
    }

    func testRoleSwapNamingBothPeopleUsesTheOriginalQuote() {
        var one = prepEvent("one", body: "Can you call Sam Sample?")
        one.senderContact = .init(id: "one", name: "Alex Example")
        let item = Brief.Item(text: "Sam asked you to call Alex.", priority: .reply, eventIDs: [one.id])
        let fixed = BriefLayout.requoted(item, event: one, speakers: ["Alex Example", "Sam Sample"])
        XCTAssertEqual(fixed?.text, "Alex Example asked: “Can you call Sam Sample?”")
    }

    func testEqualNamesCannotMergeNotificationIdentity() {
        var one = prepEvent("one"); one.senderContact = .init(id: "one", name: "Alex Example")
        var two = prepEvent("two", handle: "other@example.com"); two.senderContact = .init(id: "two", name: "Alex Example")
        let map = BriefLayout.contactIDs([one.id: one, two.id: two])
        XCTAssertNil(map["Alex Example"])
        XCTAssertEqual(map["alex@example.com"]?.id, "one")
        XCTAssertEqual(map["other@example.com"]?.id, "two")
    }

    func testConversationUsesOriginalSourcesInsteadOfRecyclingSummaryClaims() async throws {
        let event = prepEvent("original", body: "Did Sam Sample accept the invitation?")
        let store = try await prepStore([event])
        let brief = try testBrief([.init(text: "Sam Sample accepted the invitation.", priority: .fyi, eventIDs: [event.id])])
        try await store.saveBrief(StoredBrief(brief: brief, inputRevision: "synthetic", coverage: [], storedAt: prepNow))
        let model = PrepModel(text: "There is a question about an invitation.")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), clock: { prepNow }
        )
        _ = await core.handle(.ask(question: "Catch me up on my day"))
        let user = try XCTUnwrap(model.lastJob?.user)
        XCTAssertTrue(user.contains(event.id))
        XCTAssertTrue(user.contains("Did Sam Sample accept the invitation?"))
        XCTAssertFalse(user.contains("Sam Sample accepted the invitation."))
        XCTAssertTrue(user.contains("listed invitees"))
    }

    func testBriefPriorityCapKeepsEvidenceAndDoesNotRunAnotherModelJob() async throws {
        let event = prepEvent("priority", body: "Can you confirm the venue?")
        let store = try await prepStore([event])
        let model = PriorityOverflowModel(id: event.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), clock: { prepNow }
        )
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else { return XCTFail("Expected refresh") }
        await core.settle()
        let jobs = await model.jobs
        XCTAssertEqual(jobs.count, 1)
        let stored = try await store.latestBrief()
        XCTAssertEqual(stored?.brief.items.count, 4)
        XCTAssertTrue(stored?.brief.items.allSatisfy { $0.text == "Please reply." && $0.eventIDs == [event.id] } == true)
        XCTAssertLessThanOrEqual(stored?.brief.items.filter { $0.priority == .urgent }.count ?? 0, 3)
        let unsafe: [String: Any] = ["items": [["text": "Unsafe", "priority": "urgent", "event_ids": ["unknown"]]], "action": "send"]
        let corrected = CoreEngine.capUrgentLabels(unsafe)
        XCTAssertEqual(corrected["action"] as? String, "send", "correction cannot hide an attempted action")
    }

    func testRejectedAnswerCannotRetryThroughChat() async throws {
        let model = PrepModel(text: "{\"answer\":\"Invented claim.\",\"event_ids\":[\"unknown\"],\"schedule_ids\":[]}")
        let store = try await prepStore([prepEvent("invoice", body: "The invoice is ready.")])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), clock: { prepNow }
        )
        let response = await core.handle(.ask(question: "What about the invoice?"))
        XCTAssertEqual(response, .refused(code: "unknown_citation"))
        XCTAssertTrue(model.lastJob?.id.hasPrefix("ask-") == true)
    }
}

private actor PriorityOverflowModel: ModelClient {
    let id: String
    var jobs: [ModelJob] = []
    init(id: String) {
        self.id = id
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        jobs.append(job)
        let items = Array(
            repeating: ["text": "Please reply.", "priority": "urgent", "event_ids": [id]] as [String: Any],
            count: 4
        )
        let data = try JSONSerialization.data(withJSONObject: ["items": items])
        return ModelJobResult(jobID: job.id, status: .completed, text: String(decoding: data, as: UTF8.self))
    }

    func cancel(jobID _: String) async {}
}

@testable import AegisKit
import Foundation
import XCTest

/// A follow-up about what Aegis just said stays in the conversation (#54), even when its words match a message.
final class ConversationFollowUpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_700_000)

    func testAFollowUpToADescriptionStaysInTheConversation() async throws {
        let (core, model) = try await engine()
        _ = await core.handle(.ask(question: "Explain how a heat pump works"))
        guard case .answer = await core.handle(.ask(question: "How does the compressor work?")) else {
            return XCTFail("the follow-up must be answered")
        }
        let jobs = await model.jobs
        XCTAssertFalse(jobs.contains { $0.id.hasPrefix("ask-") }, "not a search of the owner's messages")
        let chat = try XCTUnwrap(jobs.last { $0.id.hasPrefix("chat-") })
        XCTAssertEqual(chat.history.map(\.owner), ["Explain how a heat pump works"])
        XCTAssertFalse(
            chat.user.contains("From your messages: "),
            "A general explanation needs conversation history, not incidental private records"
        )
        XCTAssertFalse(chat.user.contains("fridge is making a noise"))
    }

    func testWhatIsSomethingItMentionedStaysInTheConversation() async throws {
        for question in ["What is a refrigerant?", "Explain that again"] {
            let (core, model) = try await engine()
            _ = await core.handle(.ask(question: "Explain how a heat pump works"))
            _ = await core.handle(.ask(question: question))
            let jobs = await model.jobs
            XCTAssertFalse(jobs.contains { $0.id.hasPrefix("ask-") }, question)
            XCTAssertTrue(jobs.last?.id.hasPrefix("chat-") == true, question)
        }
    }

    func testAQuestionAboutTheOwnersMessagesStillCitesThem() async throws {
        for question in ["What did my messages say about the compressor?", "Who told me about the compressor?"] {
            let (core, model) = try await engine()
            _ = await core.handle(.ask(question: "Explain how a heat pump works"))
            _ = await core.handle(.ask(question: question))
            let jobs = await model.jobs
            XCTAssertTrue(jobs.last?.id.hasPrefix("ask-") == true, "\(question): answered from the messages, with citations")
        }
    }

    func testWhatCarriesOn() {
        let last = Chat.Turn(owner: "Explain how a heat pump works", aegis: "It moves heat with a compressor and a refrigerant.")
        func continues(_ text: String) -> Bool {
            FollowUpQuestion.continues(text, after: [last], now: now, calendar: .current)
        }
        for text in [
            "How does the compressor work?", "Tell me more", "Why?", "What does the refrigerant do?", "Is it efficient?",
            "What is a refrigerant?", "Explain that again", "How tall?", "Can you describe the refrigerant cycle in more detail please",
        ] {
            XCTAssertTrue(continues(text), text)
        }
        for text in [
            "What's on tomorrow?", "Did anyone email me about dinner?", "Write a poem about cats today",
            "Who told me about the compressor?", "What is my next meeting?", "Any messages about the compressor?",
        ] {
            XCTAssertFalse(continues(text), text)
        }
    }

    private func engine() async throws -> (CoreEngine, DescribingModel) {
        let store = MemoryStore()
        let event = Event(
            source: .imessage, sourceRecordID: "example-compressor", appID: nil, sender: "Example Robin", threadID: "example-thread",
            eventTime: now.addingTimeInterval(-600), eventTimeSource: .sent, captureTime: now,
            title: nil, body: "The compressor on the fridge is making a noise again", content: .complete, observations: [],
            senderHandle: "robin@example.invalid"
        )
        let refrigerant = Event(
            source: .imessage, sourceRecordID: "example-refrigerant", appID: nil, sender: "Example Robin", threadID: "example-thread",
            eventTime: now.addingTimeInterval(-500), eventTimeSource: .sent, captureTime: now,
            title: nil, body: "Picked up the refrigerant for the aircon", content: .complete, observations: [],
            senderHandle: "robin@example.invalid"
        )
        try await store.ingest(CollectionBatch(
            source: .messages, status: .init(ok: true, code: .ok), events: [event, refrigerant], checkpoint: nil
        ))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let model = DescribingModel(eventID: event.id)
        let core = try CoreEngine(
            store: store, collectors: [], model: model, persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt), options: .init(modelName: "synthetic-model"),
            clock: { [now] in now }
        )
        return (core, model)
    }
}

/// Describes a heat pump in chat; a grounded answer cites the synthetic message.
private actor DescribingModel: ModelClient {
    private(set) var jobs: [ModelJob] = []
    private let eventID: String

    init(eventID: String) {
        self.eventID = eventID
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        jobs.append(job)
        let text = job.id.hasPrefix("ask-")
            ? "{\"answer\":\"Example Robin said the fridge compressor is noisy.\",\"event_ids\":[\"\(eventID)\"],\"schedule_ids\":[]}"
            : "A heat pump moves heat from outside to inside using a compressor and a refrigerant."
        return ModelJobResult(jobID: job.id, status: .completed, text: text)
    }

    func cancel(jobID _: String) async {}
}

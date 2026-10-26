@testable import AegisKit
import XCTest

final class StreamingReplyTests: XCTestCase {
    func testOnlyFinishedSafeSentencesAreSpoken() {
        XCTAssertEqual(Chat.speakable("<think>hmm"), "")
        XCTAssertEqual(Chat.speakable("Sure. The capital of France is Paris. It has"), "Sure. The capital of France is Paris.")
        XCTAssertEqual(Chat.speakable("Okay. I've sent it to Example Alex. Anything else? "), "Okay.", "stops before a claimed action")
        XCTAssertEqual(Chat.speakable("**Right.** See ev_0123456789abcdef now. More "), "Right.")
        XCTAssertEqual(Chat.speakable("Pi is 3.14159 roughly"), "", "a decimal point isn't the end of a sentence")
        XCTAssertEqual(
            Chat.speakable("They said call +61 400 000 123. Odd. ", owner: "anything new?"),
            "They said call the number in the message. Odd."
        )
    }

    func testWhatsSpokenIsAlwaysTheStartOfTheFinalReply() {
        let full = "Morning! You've got Example stand-up at nine. Example Alex asked about Saturday, and it's raining later."
        let final = Chat.reply(full)
        for cut in stride(from: 0, through: full.count, by: 3) {
            let spoken = Chat.speakable(String(full.prefix(cut)))
            XCTAssertTrue(final.hasPrefix(spoken), "cut \(cut): \(spoken)")
        }
    }

    func testTheEngineOffersTheReplyWhileItsBeingWritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = SlowModel()
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))),
            options: .init(modelName: "synthetic-model")
        )
        let idle = await core.handle(.partialReply)
        XCTAssertEqual(idle, .partialReply(""))
        let asking = Task { await core.handle(.ask(question: "What's up?")) }
        var heard = ""
        for _ in 0 ..< 200 where heard.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            if case let .partialReply(text) = await core.handle(.partialReply) {
                heard = text
            }
        }
        XCTAssertEqual(heard, "Not much.")
        await model.finish()
        guard case let .answer(answer) = await asking.value else { return XCTFail("expected an answer") }
        XCTAssertEqual(answer.text, "Not much. You're all clear today.")
        let after = await core.handle(.partialReply)
        XCTAssertEqual(after, .partialReply(""))
    }
}

/// A model that has written half its reply and waits to be told to finish.
private actor SlowModel: ModelClient {
    private var release: CheckedContinuation<Void, Never>?
    private var running: String?

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        // The search plan (ADR-0032) isn't streamed: no plan, so the phrase rules read the question.
        if job.id.hasPrefix("plan-") {
            return ModelJobResult(jobID: job.id, status: .completed, text: "")
        }
        running = job.id
        await withCheckedContinuation { release = $0 }
        running = nil
        return ModelJobResult(jobID: job.id, status: .completed, text: "Not much. You're all clear today.")
    }

    func partial(jobID: String) async -> String? {
        jobID == running ? "Not much. You're all" : nil
    }

    func finish() {
        release?.resume()
        release = nil
    }

    func cancel(jobID _: String) async {}
}

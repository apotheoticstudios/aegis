@testable import AegisKit
import XCTest

/// Speech recognition may join chatter, questions and corrections into one turn, with or without punctuation.
final class MemoryAdmissionTests: XCTestCase {
    static let nonFacts = [
        "Not too bad. Um, what have I got on today? Not tomorrow. No, for the rest of today.",
        "Not too bad um what have I got on today not tomorrow no for the rest of today",
        "I am fine. What is on my calendar? Actually, the rest of today.",
        "I like short answers. Can you read my messages? No, my email.",
        "My question is what have I got on today",
        "I have a question about the calendar",
        "I am looking for the message from Example Store",
        "I'm a bit confused", "I am a little tired", "I'm feeling good", "Not too bad", "I like that",
        "I prefer this", "My day is going well", "My calendar is empty", "My brother is visiting today",
        "It was yesterday. From Example Store.", "I work at Example Office today",
        "Example Alex is at the concert tonight", "Example Alex was at the concert",
        "My brother is Example Alex, what did he say", "No, don't remember that.",
        "My favourite colour is blue, don't save that", "0400 000 001 is Example Alex. Nice.",
        "I am vegetarian? Actually never mind.", "I am vegetarian？ No, that is a question.",
        "The email says my brother is Example Alex", "Suppose I am vegetarian", "I want you to answer my question",
    ]

    func testAllImplicitMemoryEntryPointsRejectMixedSpeechAndTransientStatements() {
        for text in Self.nonFacts {
            XCTAssertNil(MemoryCommand.statedFact(text), text)
            XCTAssertNil(MemoryCommand.suggestion(text), text)
            XCTAssertFalse(FactExtractor.worthReading(text), text)
        }
        var book = MemoryBook.empty
        XCTAssertEqual(book.learn(Self.nonFacts, now: Date()), 0)
        XCTAssertTrue(book.notes.isEmpty)
    }

    func testDurableOwnerFactsAndExplicitMemoryRemainAvailable() {
        for fact in [
            "I'm vegetarian", "I prefer short answers", "My favourite colour is blue",
            "My sister's name is Example Sam", "Example Alex is my brother",
            "0400 000 001 is Example Alex", "example@example.com belongs to Example Sam",
            "I am a software engineer", "On Fridays I work at Example Office",
            "Example Sam works at Example Clinic", "I am training for a marathon",
        ] {
            XCTAssertEqual(MemoryCommand.statedFact(fact), fact)
            XCTAssertTrue(FactExtractor.worthReading(fact))
        }
        XCTAssertEqual(
            MemoryCommand.parse("Remember that the example appointment is tomorrow"),
            .remember("the example appointment is tomorrow")
        )
        XCTAssertEqual(
            MemoryCommand.parse("Could you remember that my favourite colour is blue?"),
            .remember("my favourite colour is blue")
        )
        XCTAssertEqual(MemoryCommand.parse("No, don't remember that."), .forget("that"))
    }

    func testSpokenDateCorrectionChoosesTheRequestedDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        for text in [
            Self.nonFacts[0],
            Self.nonFacts[1],
            "What have I got on tomorrow? Actually today.",
            "What have I got on today, not tomorrow",
        ] {
            let query = AskQuery(text, now: now, calendar: calendar)
            XCTAssertTrue(query.schedule)
            XCTAssertNil(AskSelection(text, query: query).direction, "An agenda question is not a request for incoming messages")
            XCTAssertEqual(query.calendarWindow.start, today)
            XCTAssertEqual(query.calendarWindow.end, calendar.date(byAdding: .day, value: 1, to: today))
        }
    }

    func testModelOutputCannotInventFactsOrCoerceJSONObjectsIntoNotes() {
        XCTAssertEqual(
            FactExtractor.parse(#"[null, 42, true, {"fact":"I am vegetarian"}, "I prefer metric units"]"#),
            ["I prefer metric units"]
        )
        XCTAssertEqual(MemoryFact.supported([
            "I am vegetarian", "My sister is Example Alex", "I prefer imperial units",
        ], by: ["I'm vegetarian", "I prefer metric units"]), ["I'm vegetarian"])
        XCTAssertTrue(MemoryFact.supported(["I am vegetarian"], by: ["Am I vegetarian? Not sure."]).isEmpty)
        XCTAssertTrue(MemoryFact.supported(["My email is a.b@example.com"], by: ["My email is ab@example.com"]).isEmpty)
    }

    func testAChatModelCannotClaimItSavedSomethingIncludingDuringStreaming() {
        for reply in [
            "Got it. I'll remember that you have plans today.",
            "I've saved your question.",
            "I will store that for later.",
            "Added that to my memory.", "I’ll remember that.",
        ] {
            XCTAssertNil(Chat.check(reply))
            XCTAssertEqual(Chat.reply(reply), Chat.memoryNotSaved)
            XCTAssertFalse(Chat.speakable(reply + " ").contains("remember"))
        }
        XCTAssertNotNil(Chat.check("I remember your favourite colour is blue."), "Recalling an existing fact is allowed")
    }
}

@MainActor
final class CoreMemoryAdmissionTests: XCTestCase {
    func testPausingLearningAlsoStopsImplicitFactsButExplicitMemoryStillWorks() async throws {
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: MemoryAdmissionModel(), persistence: AdmissionSchedule(),
            initial: .init(openingHour: 7, openingMinute: 0, timeZone: .gmt), options: .init(modelName: "synthetic-model")
        )
        _ = await core.handle(.ask(question: "Stop learning about me"))
        _ = await core.handle(.ask(question: "I am vegetarian"))
        guard case let .memories(empty) = await core.handle(.memories) else { return XCTFail("Expected memories") }
        XCTAssertTrue(empty.isEmpty)
        _ = await core.handle(.ask(question: "Remember that my favourite colour is blue"))
        _ = await core.handle(.ask(question: "You can learn about me again"))
        _ = await core.handle(.ask(question: "I am vegetarian"))
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected memories") }
        XCTAssertEqual(Set(notes.map(\.text)), ["my favourite colour is blue", "I am vegetarian"])
    }

    func testQuestionIsAnsweredRatherThanSavedAndCannotEnterBackgroundLearning() async throws {
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: MemoryAdmissionModel(), persistence: AdmissionSchedule(),
            initial: .init(openingHour: 7, openingMinute: 0, timeZone: .gmt), options: .init(modelName: "synthetic-model")
        )
        _ = await core.handle(.ask(question: "My favourite colour is blue"))
        for text in MemoryAdmissionTests.nonFacts where !text.contains("remember") {
            guard case let .answer(answer) = await core.handle(.ask(question: text)) else { return XCTFail("Expected answer") }
            XCTAssertNotEqual(answer.model, "memory", text)
            await core.queueLearning(text)
        }
        let queued = await core.learnQueue
        XCTAssertTrue(queued.isEmpty)
        _ = await core.handle(.ask(question: "No, don't remember that."))
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected memories") }
        XCTAssertEqual(notes.map(\.text), ["My favourite colour is blue"], "A rejection of chatter must not delete an unrelated note")
    }
}

private struct MemoryAdmissionModel: ModelClient {
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        .init(jobID: job.id, status: .completed, text: "I couldn't find a matching appointment.")
    }

    func cancel(jobID _: String) async {}
}

private struct AdmissionSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

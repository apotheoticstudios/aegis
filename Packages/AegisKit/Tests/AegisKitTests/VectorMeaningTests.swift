@testable import AegisKit
import Foundation
import XCTest

/// Synthetic vectors only; no embedding model or owner data is read.
@MainActor
final class VectorMeaningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let car = "The car needs new tyres"
    private let question = "Any advice for my Mazda?"
    private var asked: String {
        VectorMeaning.queryPrefix + question
    }

    func testScoresNormalisedVectorsAndIgnoresTheQuestionString() throws {
        let scorer = VectorMeaning(question: [1, 0], vectors: [
            "same": [1, 0], "related": [0.8, 0.6], "below": [0.5, 0.866],
            "unrelated": [0, 1], "opposite": [-1, 0],
        ])
        XCTAssertEqual(VectorMeaning.threshold, 0.55)
        XCTAssertEqual(scorer.relatedness("ignored", "same"), 1)
        XCTAssertEqual(try XCTUnwrap(scorer.relatedness("different words", "related")), 0.8, accuracy: 0.000001)
        XCTAssertNil(scorer.relatedness("ignored", "below"))
        XCTAssertNil(scorer.relatedness("ignored", "unrelated"))
        XCTAssertNil(scorer.relatedness("ignored", "opposite"))
    }

    func testThresholdIsInclusiveAndCanBeConfigured() {
        let exact = VectorMeaning(question: [1, 0], vectors: ["note": [1, 0]], threshold: 1)
        XCTAssertEqual(exact.relatedness("ignored", "note"), 1)
        let lower = VectorMeaning(question: [1, 0], vectors: ["note": [0.6, 0.8]], threshold: 0.5)
        XCTAssertNotNil(lower.relatedness("ignored", "note"))
        let higher = VectorMeaning(question: [1, 0], vectors: ["note": [0.8, 0.6]], threshold: 0.9)
        XCTAssertNil(higher.relatedness("ignored", "note"))
    }

    func testMissingIncompatibleAndNonFiniteVectorsReturnNil() {
        let scorer = VectorMeaning(question: [1, 0], vectors: [
            "short": [1], "long": [1, 0, 0], "empty": [], "nan": [.nan, 0], "infinite": [.infinity, 0],
        ])
        for note in ["missing", "short", "long", "empty", "nan", "infinite"] {
            XCTAssertNil(scorer.relatedness("ignored", note))
        }
        XCTAssertNil(VectorMeaning(question: [], vectors: ["note": []]).relatedness("ignored", "note"))
    }

    func testExistingModelClientsDefaultToUnavailableEmbeddings() async {
        let embedded = await FailingModel().embed(["Synthetic input"])
        XCTAssertNil(embedded)
    }

    func testChatRecallsANoteByVectorAndSecondChatOnlyEmbedsTheQuestion() async throws {
        let book = MemoryBook(notes: [note(car)])
        XCTAssertTrue(book.notesForChat(question, now: now, calendar: .current).isEmpty)
        let model = SyntheticVectorModel()
        let core = try engine(model: model, book: book)

        guard case .answer = await core.handle(.ask(question: question)) else { return XCTFail("Expected chat answer") }
        let firstInput = await model.inputs.last
        XCTAssertTrue(firstInput?.contains(car) == true)
        XCTAssertTrue(firstInput?.contains("The owner told you (") == true)

        guard case .answer = await core.handle(.ask(question: question)) else { return XCTFail("Expected second chat answer") }
        let batches = await model.batches
        // The first question became an earlier conversation, embedded once as a stored item.
        XCTAssertEqual(batches, [[car, asked], [question, asked]])
    }

    func testChatRecallsAnEarlierExchangeByItsOwnerVector() async throws {
        let exchange = PastExchange(at: now.addingTimeInterval(-86400), owner: car, aegis: "Synthetic tyre advice.")
        let book = MemoryBook(exchanges: [exchange])
        XCTAssertTrue(book.notesForChat(question, now: now, calendar: .current).isEmpty)
        let model = SyntheticVectorModel()
        let core = try engine(model: model, book: book)
        guard case .answer = await core.handle(.ask(question: question)) else { return XCTFail("Expected chat answer") }
        let input = await model.inputs.last
        let batches = await model.batches
        XCTAssertTrue(input?.contains("Earlier (") == true)
        XCTAssertTrue(input?.contains(exchange.aegis) == true)
        XCTAssertEqual(batches, [[car, asked]])
    }

    func testCandidatesExcludePreferencesQuarantineAndRepliesAndDeduplicateText() async throws {
        let shortcut = MemoryNote(id: "shortcut", kind: .shortcut, text: "Synthetic shortcut", createdAt: now)
        let book = MemoryBook(notes: [
            note(car), note(car, id: "duplicate"), shortcut,
            MemoryNote(id: "preference", kind: .preference, text: "Synthetic preference", createdAt: now),
            MemoryNote(id: "quarantine", kind: .fact, text: "Synthetic quarantine", createdAt: now, origin: .quarantined),
        ], exchanges: [
            PastExchange(at: now, owner: car, aegis: "Synthetic reply excluded"),
            PastExchange(at: now, owner: question, aegis: "Another reply excluded"),
        ])
        let model = SyntheticVectorModel()
        let core = try engine(model: model, book: book)
        _ = await core.meaningScorer(for: question)
        _ = await core.meaningScorer(for: question)
        let batches = await model.batches
        XCTAssertEqual(batches, [[car, shortcut.text, question, asked], [asked]])
    }

    func testUnavailableEmbeddingsFallBackToMeaningAndCacheNothing() async throws {
        let model = SyntheticVectorModel(response: .unavailable)
        let core = try engine(model: model, book: MemoryBook(notes: [note(car)]), meaning: SyntheticCarMeaning())
        guard case .answer = await core.handle(.ask(question: question)) else { return XCTFail("Expected fallback answer") }
        let input = await model.inputs.last
        let cache = await core.meaningVectors
        XCTAssertTrue(input?.contains(car) == true)
        XCTAssertTrue(cache.isEmpty)

        await model.respond(with: .vectors)
        _ = await core.meaningScorer(for: question)
        let batches = await model.batches
        XCTAssertEqual(batches, [[car, asked], [car, question, asked]])
    }

    func testUnavailableEmbeddingsWithoutFallbackKeepWordRecall() async throws {
        let model = SyntheticVectorModel(response: .unavailable)
        let core = try engine(model: model, book: MemoryBook(notes: [note(car)]))
        let scorer = await core.meaningScorer(for: question)
        XCTAssertNil(scorer)
        guard case .answer = await core.handle(.ask(question: question)) else { return XCTFail("Expected word-only answer") }
        let unrelatedInput = await model.inputs.last
        XCTAssertFalse(unrelatedInput?.contains(car) == true)
        let wordScorer = await core.meaningScorer(for: "car tyres")
        let book = await core.memory
        XCTAssertTrue(book.notesForChat("car tyres", now: now, calendar: .current, meaning: wordScorer).contains { $0.contains(car) })
    }

    func testWrongEmbeddingCountFallsBackWithoutChangingTheCache() async throws {
        for response in [SyntheticVectorModel.Response.tooFew, .tooMany] {
            let model = SyntheticVectorModel()
            let core = try engine(model: model, book: MemoryBook(notes: [note(car)]), meaning: SyntheticCarMeaning())
            _ = await core.meaningScorer(for: question)
            let before = await core.meaningVectors
            await model.respond(with: response)
            let scorer = await core.meaningScorer(for: "Synthetic uncached question")
            let after = await core.meaningVectors
            XCTAssertEqual(after, before)
            XCTAssertEqual(scorer?.relatedness(question, car), 0.75)
        }
    }

    func testCacheResetAtCapacityStillReturnsAllCandidateVectors() async throws {
        // Construct an oversized synthetic book directly to exercise the cache cap in a single batch.
        let notes = (0 ..< 2000).map { note("Synthetic note \($0)", id: "note-\($0)") }
        let model = SyntheticVectorModel()
        let core = try engine(model: model, book: MemoryBook(notes: notes))
        let scorer = await core.meaningScorer(for: question)
        let cache = await core.meaningVectors
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(scorer?.relatedness(question, "Synthetic note 0"), 1)
        XCTAssertEqual(scorer?.relatedness(question, "Synthetic note 1999"), 1)
        let batches = await model.batches
        XCTAssertEqual(batches.map(\.count), [2001])
    }

    private func note(_ text: String, id: String = "car") -> MemoryNote {
        MemoryNote(id: id, kind: .fact, text: text, createdAt: now)
    }

    private func engine(model: any ModelClient, book: MemoryBook, meaning: (any MeaningScorer)? = nil) throws -> CoreEngine {
        var paused = book
        paused.learningPaused = true
        let time = now
        return try CoreEngine(
            store: MemoryStore(), collectors: [], model: model, persistence: SyntheticVectorSchedule(),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), memory: SyntheticVectorMemory(book: paused), meaning: meaning,
            clock: { time }
        )
    }
}

private actor SyntheticVectorModel: ModelClient {
    enum Response { case vectors, unavailable, tooFew, tooMany }

    private var response: Response
    private(set) var batches: [[String]] = []
    private(set) var inputs: [String] = []

    init(response: Response = .vectors) {
        self.response = response
    }

    func respond(with response: Response) {
        self.response = response
    }

    func embed(_ texts: [String]) async -> [[Float]]? {
        batches.append(texts)
        switch response {
        case .vectors: return texts.map { _ in [1, 0] }
        case .unavailable: return nil
        case .tooFew: return Array(texts.dropLast()).map { _ in [1, 0] }
        case .tooMany: return (texts + ["extra"]).map { _ in [1, 0] }
        }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        inputs.append(job.user)
        return ModelJobResult(jobID: job.id, status: .completed, text: "Synthetic reply.")
    }

    func cancel(jobID _: String) async {}
}

private struct SyntheticCarMeaning: MeaningScorer {
    func relatedness(_ question: String, _ note: String) -> Double? {
        question.contains("Mazda") && note.contains("car") ? 0.75 : nil
    }
}

private struct SyntheticVectorMemory: MemoryPersistence {
    let book: MemoryBook
    func load() throws -> MemoryBook {
        book
    }

    func save(_: MemoryBook) throws {}
}

private struct SyntheticVectorSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

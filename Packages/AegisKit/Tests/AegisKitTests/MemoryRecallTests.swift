@testable import AegisKit
import XCTest

/// Memory recall by meaning (#305): Hindsight's rank fusion and the meaning arm, with a stand-in scorer.
final class MemoryRecallTests: XCTestCase {
    func testRankFusionRewardsAgreementAndKeepsFirstSeenOrderOnTies() {
        // c: 1/63 + 1/61 just beats b: 1/62 + 1/62.
        XCTAssertEqual(RankFusion.fuse([["a", "b", "c"], ["c", "b"]]), ["c", "b", "a"])
        XCTAssertEqual(RankFusion.fuse([["x"], ["y"]]), ["x", "y"])
        XCTAssertEqual(RankFusion.fuse([["a", "b", "c"]], cap: 2), ["a", "b"])
    }

    func testMeaningRecallsANoteWithoutSharedWords() {
        var book = MemoryBook.empty
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = book.remember("my sister is called Example Sam", now: now)
        _ = book.remember("the gym code is 4312", now: now)
        XCTAssertTrue(book.relevant(to: "who is my sibling?").isEmpty, "words alone miss it")
        let recalled = book.relevant(to: "who is my sibling?", meaning: Synonyms())
        XCTAssertEqual(recalled.map(\.text), ["my sister is called Example Sam"])
        XCTAssertEqual(book.relevant(to: "what is the gym code", meaning: Synonyms()).first?.text, "the gym code is 4312")
    }
}

extension MemoryRecallTests {
    func testMeaningRecallsAnEarlierConversationWithoutSharedWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var book = MemoryBook.empty
        book.record(PastExchange(
            at: now.addingTimeInterval(-7200),
            owner: "What should I get my sister for her birthday?",
            aegis: "A book."
        ))
        book.record(PastExchange(at: now.addingTimeInterval(-3600), owner: "What's the weather?", aegis: "Sunny."))
        XCTAssertTrue(book.earlier(about: "ideas for my sibling", before: now).isEmpty, "words alone miss it")
        let recalled = book.earlier(about: "ideas for my sibling", before: now, meaning: Synonyms())
        XCTAssertEqual(recalled.map(\.aegis), ["A book."])
        XCTAssertEqual(book.earlier(about: "the weather", before: now, meaning: Synonyms()).map(\.aegis), ["Sunny."])
    }
}

/// Relates "sibling" to "sister" only.
private struct Synonyms: MeaningScorer {
    func relatedness(_ question: String, _ note: String) -> Double? {
        question.contains("sibling") && note.contains("sister") ? 0.6 : nil
    }
}

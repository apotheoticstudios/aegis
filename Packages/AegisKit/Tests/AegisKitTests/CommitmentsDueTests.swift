@testable import AegisKit
import Foundation
import XCTest

final class CommitmentsDueTests: XCTestCase {
    private func due(_ phrase: String, madeAt: Date = CommitmentFixture.date()) -> Date? {
        CommitmentFixture.compute([
            CommitmentFixture.event("promise", "I'll send it " + phrase, at: madeAt),
        ], now: madeAt.addingTimeInterval(1)).first?.due
    }

    private func end(_ day: Int) -> Date {
        CommitmentFixture.date(day, hour: 23, minute: 59, second: 59)
    }

    func testTodayAndTomorrowAliases() {
        for phrase in ["today", "tonight", "this morning", "this afternoon", "this evening", "later today", "by end of day", "EOD"] {
            XCTAssertEqual(due(phrase), end(7), phrase)
        }
        for phrase in ["tomorrow", "tmrw", "tmr", "tomoz", "tomorrow morning", "tomorrow afternoon", "tomorrow night"] {
            XCTAssertEqual(due(phrase), end(8), phrase)
        }
    }

    func testEveryWeekdayIncludingTodayVersusNext() {
        let days = ["Wednesday": 7, "Thursday": 8, "Friday": 9, "Saturday": 10, "Sunday": 11, "Monday": 12, "Tuesday": 13]
        for (name, day) in days {
            for prefix in ["", "on ", "by ", "this "] {
                XCTAssertEqual(due(prefix + name), end(day), prefix + name)
            }
            XCTAssertEqual(due("next " + name), end(day + 7), name)
        }
    }

    func testWeekendAndWeekPhrases() {
        for phrase in ["this weekend", "by the weekend"] {
            XCTAssertEqual(due(phrase), end(10), phrase)
            XCTAssertEqual(due(phrase, madeAt: CommitmentFixture.date(10)), end(10), phrase)
            XCTAssertEqual(due(phrase, madeAt: CommitmentFixture.date(11)), end(17), phrase)
        }
        XCTAssertEqual(due("next week"), end(12))
        XCTAssertEqual(due("next week", madeAt: CommitmentFixture.date(12)), end(19))
        for phrase in ["this week", "by end of week"] {
            XCTAssertEqual(due(phrase), end(9), phrase)
            XCTAssertEqual(due(phrase, madeAt: CommitmentFixture.date(10)), end(16), phrase)
        }
    }

    func testRelativeIntervalsAndVaguePhrases() {
        let madeAt = CommitmentFixture.date()
        let intervals: [(String, TimeInterval)] = [
            ("in 1 minute", 60), ("in 15 minutes", 900), ("in 1 hour", 3600), ("in 2 hours", 7200),
            ("in 1 day", 86400), ("in 2 days", 172_800), ("in a minute", 3600), ("in a sec", 3600),
            ("in a bit", 3600), ("in an hour", 3600),
        ]
        for (phrase, seconds) in intervals {
            XCTAssertEqual(due(phrase), madeAt.addingTimeInterval(seconds), phrase)
        }
        for phrase in ["soon", "later", "asap", "", "in zero hours", "at 25:00", "at 5:99pm"] {
            XCTAssertNil(due(phrase), phrase)
        }
    }

    func testClockTimesPastTimesAndCombinedDays() {
        let cases: [(String, Date)] = [
            ("at 5", CommitmentFixture.date(8, hour: 5)), ("by 5", CommitmentFixture.date(8, hour: 5)),
            ("5pm", CommitmentFixture.date(hour: 17)), ("5:30pm", CommitmentFixture.date(hour: 17, minute: 30)),
            ("17:00", CommitmentFixture.date(hour: 17)), ("9am", CommitmentFixture.date(8, hour: 9)),
            ("tomorrow at 3pm", CommitmentFixture.date(8, hour: 15)),
            ("Friday by 5:30pm", CommitmentFixture.date(9, hour: 17, minute: 30)),
            ("today at 9am", CommitmentFixture.date(hour: 9)), ("12am", CommitmentFixture.date(8, hour: 0)),
            ("12pm", CommitmentFixture.date(hour: 12)),
        ]
        for (phrase, expected) in cases {
            XCTAssertEqual(due(phrase), expected, phrase)
        }
        XCTAssertEqual(due("at 10"), CommitmentFixture.date())
    }

    func testDueIsRelativeToMadeAtInsteadOfNowAndQuotedDatesDoNotCount() {
        let promise = CommitmentFixture.event("promise", "I'll send it tomorrow", at: CommitmentFixture.date(6))
        XCTAssertEqual(CommitmentFixture.compute([promise], now: CommitmentFixture.date(8)).first?.due, end(7))
        XCTAssertNil(due("\"tomorrow\""))
    }
}

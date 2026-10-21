@testable import AegisKit
import XCTest

final class QuickAnswerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .gmt
        return value
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 16, minute: 5)) ?? .distantPast
    }

    private func ask(_ text: String) -> String? {
        QuickAnswer.answer(text, now: now, calendar: calendar, locale: Locale(identifier: "en_AU"))
    }

    func testTimeAndDate() {
        // en_AU's am/pm is lowercase on macOS and uppercase in Linux Foundation's CLDR data.
        XCTAssertEqual(ask("What time is it?")?.lowercased(), "it's 4:05 pm.")
        XCTAssertEqual(ask("Hey Aegis, what's the date today"), "It's Monday 12 October 2026.")
        XCTAssertNil(ask("What time is it in London?"), "time zones go to the conversation")
    }

    func testDaysUntil() {
        XCTAssertEqual(ask("How many days until Christmas?"), "It's 74 days until Christmas.")
        XCTAssertEqual(ask("how long until the 13th of October"), "13 October is tomorrow.")
        XCTAssertEqual(ask("How many days until 1 March"), "It's 140 days until 1 March.")
        XCTAssertNil(ask("How long until my birthday?"))
    }

    func testArithmetic() {
        XCTAssertEqual(ask("What's 15% of 240?"), "That's 36.")
        XCTAssertEqual(ask("what is 12 times 37"), "That's 444.")
        XCTAssertEqual(ask("Calculate (3 + 4) * 2"), "That's 14.")
        XCTAssertEqual(ask("square root of 144"), "That's 12.")
        XCTAssertEqual(ask("what's 10 divided by 4"), "That's 2.5.")
        XCTAssertEqual(ask("2 to the power of 10"), "That's 1,024.")
        XCTAssertEqual(ask("what's 1,200 x 3"), "That's 3,600.")
        XCTAssertEqual(ask("what's 5 / 0"), "That's undefined: you can't divide by zero.")
        for line in ["What's up?", "what is 42", "Call 0400 000 123", "What's the plan for Saturday?"] {
            XCTAssertNil(ask(line), line)
        }
    }

    func testConversions() {
        XCTAssertEqual(ask("10 km in miles"), "10 kilometres is 6.21 miles.")
        XCTAssertEqual(ask("Convert 30 c to f"), "30 degrees Celsius is 86 degrees Fahrenheit.")
        XCTAssertEqual(ask("how many pounds in 5 kg?"), "5 kilograms is 11.02 pounds.")
        XCTAssertEqual(ask("what's 1 mile in km"), "1 mile is 1.61 kilometres.")
        XCTAssertNil(ask("5 kg in miles"), "different kinds of unit")
        XCTAssertEqual(ask("1,000 m in km"), "1,000 metres is 1 kilometre.")
        XCTAssertEqual(ask("1,000,000 g in kg"), "1,000,000 grams is 1,000 kilograms.")
        XCTAssertNil(ask("1,5 km in miles"), "ambiguous decimal comma in an Australian calculator")
        XCTAssertEqual(ask("1 mm in miles"), "1 millimetre is 0.0000006214 miles.")
    }

    func testPowerPrecedenceAndUndefinedResults() {
        XCTAssertEqual(ask("-2^2"), "That's -4.")
        XCTAssertEqual(ask("(-2)^2"), "That's 4.")
        XCTAssertEqual(ask("2^-2"), "That's 0.25.")
        XCTAssertEqual(ask("2^3^2"), "That's 512.")
        XCTAssertEqual(ask("square root of 9 squared"), "That's 9.")
        XCTAssertEqual(ask("10^1000"), "That's undefined or too large to calculate.")
        XCTAssertEqual(ask("1,000,000 + 1"), "That's 1,000,001.")
        XCTAssertEqual(ask("1 / 100000"), "That's 0.00001.")
        XCTAssertNil(ask("1,20 + 3"))
        XCTAssertNil(ask("5+"))
    }

    func testDatesAreRealAndRollAcrossYears() throws {
        let december = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23)))
        XCTAssertEqual(QuickAnswer.answer("days", now: december, calendar: calendar), nil)
        XCTAssertEqual(QuickAnswer.answer("how long until new year", now: december, calendar: calendar), "New Year's Day is tomorrow.")
        XCTAssertEqual(ask("how long until 29 February"), "It's 505 days until 29 February.")
        XCTAssertNil(ask("how long until 31 April"))
        XCTAssertNil(ask("how long until 30 February"))
        XCTAssertNil(ask("how long until 3 marchioness"))
    }

    func testTheEngineAnswersWithoutTheModel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RecordingModel()
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone),
            options: .init(modelName: "synthetic-model"), calendar: calendar, clock: { [now] in now }
        )
        guard case let .answer(answer) = await core.handle(.ask(question: "What's 15% of 240?")) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(answer.text, "That's 36.")
        XCTAssertNil(model.lastInput)
    }
}

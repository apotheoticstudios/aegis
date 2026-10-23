@testable import AegisKit
import XCTest

final class ActionCommandTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .gmt
        return value
    }

    /// Monday 19 October 2026, 2:00 pm in Brisbane.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14)) ?? .distantPast
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func parse(_ text: String) -> ActionCommand? {
        ActionCommand.parse(text, now: now, calendar: calendar)
    }

    func testReminders() {
        XCTAssertEqual(parse("Remind me to call Mum at 5"), .reminder(title: "Call Mum", due: at(19, 17)))
        XCTAssertEqual(parse("hey aegis, remind me to take the bins out tonight"), .reminder(title: "Take the bins out", due: at(19, 19)))
        XCTAssertEqual(parse("remind me to buy milk tomorrow morning"), .reminder(title: "Buy milk", due: at(20, 9)))
        XCTAssertEqual(
            parse("remind me to check the oven in 20 minutes"),
            .reminder(title: "Check the oven", due: now.addingTimeInterval(1200))
        )
        XCTAssertEqual(parse("remind me to renew the rego on Friday"), .reminder(title: "Renew the rego", due: at(23, 9)))
        XCTAssertEqual(parse("Remind me to stretch at 9am"), .reminder(title: "Stretch", due: at(20, 9)), "9 am has passed: tomorrow")
        XCTAssertEqual(parse("remind me to water the plants"), .reminder(title: "Water the plants", due: nil))
    }

    func testCalendarEvents() {
        XCTAssertEqual(
            parse("Add dentist to my calendar on Tuesday at 3pm"),
            .event(title: "Dentist", start: at(20, 15), end: at(20, 16))
        )
        XCTAssertEqual(
            parse("Schedule a meeting with Example Alex tomorrow at 10:30 am for 30 minutes"),
            .event(title: "Meeting with Example Alex", start: at(20, 10, 30), end: at(20, 11))
        )
        XCTAssertEqual(
            parse("put Example Sam's birthday party in the calendar on 25 October"),
            .event(title: "Example Sam's birthday party", start: at(25, 0), end: at(26, 0))
        )
        XCTAssertNil(parse("add milk to the shopping list"), "not a calendar")
        XCTAssertNil(parse("add a meeting to my calendar"), "no time")
        XCTAssertNil(parse("What's on my calendar tomorrow?"))
    }

    func testTheCardSaysExactlyWhatWillBeAdded() {
        let reminder = ActionCommand.reminder(title: "Call Mum", due: at(19, 17))
        XCTAssertTrue(reminder.summary(calendar: calendar, locale: Locale(identifier: "en_AU")).hasPrefix("Add the reminder “Call Mum”, "))
        XCTAssertTrue(reminder.summary(calendar: calendar, locale: Locale(identifier: "en_AU")).hasSuffix("at 5:00 pm?"))
        XCTAssertEqual(
            ActionPolicy.decision(for: ActionRequest(payload: reminder.payload, origin: .ownerTyped), settings: .init(panelIsOpen: true))
                .tier,
            .confirm
        )
    }
}

final class ActionFollowUpTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .gmt
        return value
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14)) ?? .distantPast
    }

    func testAppsMovesAndUndo() {
        XCTAssertEqual(ActionCommand.parse("Open Spotify", now: now, calendar: calendar), .openApp(name: "Spotify"))
        XCTAssertEqual(ActionCommand.parse("hey aegis, launch the Notes app", now: now, calendar: calendar), .openApp(name: "Notes"))
        XCTAssertNil(ActionCommand.parse("open the world view", now: now, calendar: calendar), "the World view isn't an app")
        let six = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18))
        XCTAssertEqual(ActionCommand.parse("move it to 6pm", now: now, calendar: calendar), .moveLast(to: six ?? now, allDay: false))
        XCTAssertEqual(ActionCommand.parse("undo that", now: now, calendar: calendar), .removeLast)
        let policy = { (command: ActionCommand) in
            ActionPolicy.decision(for: ActionRequest(payload: command.payload, origin: .ownerSpoken), settings: .init(panelIsOpen: true))
                .tier
        }
        XCTAssertEqual(policy(.openApp(name: "Spotify")), .auto, "opening an app is harmless")
        XCTAssertEqual(policy(.moveLast(to: now, allDay: false)), .confirm)
        XCTAssertEqual(policy(.removeLast), .never, "deleting is on the never-list")
    }

    func testYesAndNoAnswerTheCard() {
        for line in ["Yes", "yes, add it", "Go ahead.", "do it", "OK", "run it", "yes, open it"] {
            XCTAssertEqual(ActionReply.parse(line), true, line)
        }
        for line in ["no", "Cancel", "never mind", "nah"] {
            XCTAssertEqual(ActionReply.parse(line), false, line)
        }
        XCTAssertNil(ActionReply.parse("yes I think the dentist is at 3"), "a sentence isn't a yes")
    }
}

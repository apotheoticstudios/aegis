@testable import AegisKit
import XCTest

final class CalendarAttendeeTests: XCTestCase {
    private func occurrence(attendees: [CalendarAttendee]?) -> CalendarOccurrence {
        let start = Date(timeIntervalSince1970: 1_791_700_000)
        return CalendarOccurrence(
            itemID: "item-1", occurrenceDate: nil, calendarTitle: "Work", title: "Example planning", start: start,
            end: start.addingTimeInterval(1800), isAllDay: false, timeZone: "Australia/Brisbane", location: nil,
            status: .confirmed, captureTime: start, attendees: attendees
        )
    }

    func testAttendeesRoundTripAndStayOutOfTheJSONWhenAbsent() throws {
        let with = occurrence(attendees: [
            CalendarAttendee(name: "Example Alex", email: "alex@example.com", isOwner: false),
            CalendarAttendee(name: nil, email: "owner@example.com", isOwner: true),
        ])
        let data = try JSONEncoder().encode(with)
        XCTAssertEqual(try JSONDecoder().decode(CalendarOccurrence.self, from: data), with)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"is_owner\":true"))

        let without = try JSONEncoder().encode(occurrence(attendees: nil))
        XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("attendees"), "earlier records are unchanged")
        XCTAssertNil(try JSONDecoder().decode(CalendarOccurrence.self, from: without).attendees)
    }
}

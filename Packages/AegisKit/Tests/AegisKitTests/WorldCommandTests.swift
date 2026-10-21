@testable import AegisKit
import XCTest

final class WorldCommandTests: XCTestCase {
    private func tool(_ text: String, open: Bool = false, home: String? = "Brisbane") -> (String, WorldValue)? {
        guard case let .tool(name, arguments) = WorldCommand.parse(text, worldOpen: open, homeCity: home) else { return nil }
        return (name, arguments)
    }

    private func place(_ name: String) -> WorldValue {
        .object(["place": .string(name)])
    }

    func testFlightsShipsQuakesFiresAndSatellites() {
        XCTAssertEqual(tool("Hey Aegis, show flights over Brisbane")?.0, "aircraft_in_area")
        XCTAssertEqual(tool("any planes near Sydney right now?")?.1, .object(["area": place("sydney"), "limit": .number(25)]))
        XCTAssertEqual(
            tool("military aircraft over Taiwan")?.1,
            .object(["area": place("taiwan"), "limit": .number(25), "military": .bool(true)])
        )
        XCTAssertEqual(tool("ships near Gladstone")?.0, "vessels_in_area")
        XCTAssertEqual(tool("Any earthquakes?")?.1, .object(["limit": .number(10)]))
        XCTAssertEqual(tool("earthquakes near Japan")?.1, .object(["area": place("japan"), "limit": .number(10)]))
        XCTAssertEqual(tool("bushfires near Toowoomba")?.0, "get_active_fires")
        XCTAssertEqual(tool("Where's the ISS?")?.1, .object(["location": place("Brisbane")]), "defaults to the Mac's city")
        XCTAssertEqual(tool("next ISS pass over Perth")?.1, .object(["location": place("perth")]))
        XCTAssertEqual(tool("satellites above London")?.0, "satellites_overhead")
        XCTAssertEqual(tool("any cyclones?")?.0, "get_cyclones")
        XCTAssertEqual(tool("rain radar over Brisbane")?.1, .object(["map": .string("radar"), "area": place("brisbane")]))
        XCTAssertEqual(tool("lightning over Darwin")?.1, .object(["map": .string("lightning"), "area": place("darwin")]))
        XCTAssertEqual(tool("show recent rocket launches")?.0, "get_recent_launches")
    }

    func testMovingTheGlobe() {
        XCTAssertEqual(tool("Fly to Tokyo")?.1, .object(["area": place("tokyo")]))
        XCTAssertEqual(tool("show me Paris on the globe")?.1, .object(["area": place("paris")]))
        XCTAssertNil(tool("show me Paris"), "only while the globe is showing")
        XCTAssertEqual(tool("show me Paris", open: true)?.1, .object(["area": place("paris")]))
        XCTAssertEqual(WorldCommand.parse("open the world view", worldOpen: false), .open)
        XCTAssertEqual(WorldCommand.parse("Close the globe.", worldOpen: true), .close)
    }

    func testOwnPlacesAndOtherQuestionsArentWorldCommands() {
        guard case .declined = WorldCommand.parse("flights over my office", worldOpen: true) else { return XCTFail("own places") }
        guard case let .tool(_, house) = WorldCommand.parse("flights over my house", worldOpen: true), WorldCommand.needsHome(house) else {
            return XCTFail("home is filled in on the Mac")
        }
        guard case .declined = WorldCommand.parse("Where's the ISS?", worldOpen: false, homeCity: nil)
        else { return XCTFail("needs a place") }
        for line in ["What's up?", "Is my flight delayed?", "show me my brief", "Remember that my flight is at 6", "When is the dentist?"] {
            XCTAssertNil(WorldCommand.parse(line, worldOpen: false), line)
        }
    }

    func testCameraLayersAreNeverTurnedOn() {}
}

final class OwnerPlacesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ title: String,
        in hours: Double,
        at point: CalendarOccurrence.Coordinate? = nil,
        location: String? = nil
    ) -> CalendarOccurrence {
        CalendarOccurrence(
            itemID: "item-\(title)", occurrenceDate: nil, calendarTitle: "Example", title: title,
            start: now.addingTimeInterval(hours * 3600), end: now.addingTimeInterval(hours * 3600 + 3600), isAllDay: false,
            timeZone: "Australia/Brisbane", location: location, status: .confirmed, captureTime: now, coordinate: point
        )
    }

    func testTripsArePinnedFromCalendarCoordinatesOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let view = OwnerPlaces.tripsView([
            event("Example conference", in: 30, at: .init(latitude: -33.87, longitude: 151.21)),
            event("Example dinner", in: 5, at: .init(latitude: -27.47, longitude: 153.03)),
            event("No map location", in: 2, location: "Somewhere"),
        ], now: now, calendar: calendar)
        guard case let .object(parts) = view, case let .array(pins) = parts["annotations"] else { return XCTFail("a view") }
        XCTAssertEqual(pins.count, 2)
        guard case let .object(first) = pins[0], case let .string(label) = first["label"] else { return XCTFail("a pin") }
        XCTAssertTrue(label.hasPrefix("Example dinner · "), "soonest first")
        XCTAssertNil(OwnerPlaces.tripsView([event("No map location", in: 2)], now: now, calendar: calendar))
        XCTAssertEqual(WorldCommand.parse("Show my trips on the globe", worldOpen: false), .myTrips)
        XCTAssertEqual(WorldCommand.parse("where am I going this week?", worldOpen: false), .myTrips)
    }

    func testTheNextFlightComesFromTheCalendar() {
        XCTAssertEqual(OwnerPlaces.flight(in: "Flight to Sydney QF 520")?.callsign, "QFA520")
        XCTAssertEqual(OwnerPlaces.flight(in: "VA923 BNE-MEL")?.number, "VA923")
        XCTAssertNil(OwnerPlaces.flight(in: "Meet AB 12 at the cafe"), "unknown airline code")
        let next = OwnerPlaces.nextFlight([
            event("Dentist", in: 1), event("Flight JQ 811 to Cairns", in: 20), event("Flight QF1 to London", in: 200),
        ], now: now)
        XCTAssertEqual(next?.callsign, "JST811")
        XCTAssertEqual(WorldCommand.parse("Where's my flight?", worldOpen: false), .myFlight)
        XCTAssertEqual(WorldCommand.parse("is my plane in the air", worldOpen: false), .myFlight)
    }

    func testCoordinatesRoundTripInTheCalendarContract() throws {
        let original = event("Example conference", in: 3, at: .init(latitude: -33.87, longitude: 151.21))
        let decoded = try JSONDecoder().decode(CalendarOccurrence.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.coordinate, original.coordinate)
        let plain = try JSONEncoder().encode(event("Plain", in: 1))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("coordinate"), "absent when nil")
    }
}

final class WorldHomeAndBriefTests: XCTestCase {
    func testHomeIsSetHereAndSentOnlyRounded() {
        XCTAssertEqual(WorldCommand.parse("Set my home here", worldOpen: false), .setHome)
        XCTAssertEqual(WorldCommand.parse("this is home", worldOpen: false), .setHome)
        XCTAssertEqual(WorldCommand.parse("show me my home", worldOpen: false), .myHome)
        guard case let .tool(name, arguments) = WorldCommand.parse("flights near home", worldOpen: false) else {
            return XCTFail("flights near home")
        }
        XCTAssertEqual(name, "aircraft_in_area")
        XCTAssertTrue(WorldCommand.needsHome(arguments))
        let filled = WorldCommand.fillingHome(arguments, latitude: -27.4712, longitude: 153.0251)
        XCTAssertEqual(
            filled,
            .object(["area": .object(["lat": .number(-27.5), "lon": .number(153.0), "radius_km": .number(50)]), "limit": .number(25)])
        )
        guard case let .tool(_, iss) = WorldCommand.parse("next ISS pass over home", worldOpen: false) else { return XCTFail("ISS") }
        XCTAssertEqual(
            WorldCommand.fillingHome(iss, latitude: -27.47, longitude: 153.02),
            .object(["location": .object(["lat": .number(-27.5), "lon": .number(153.0)])])
        )
        guard case .declined = WorldCommand.parse("flights over my office", worldOpen: false) else { return XCTFail("other own places") }
    }

    func testWeatherAtHomeReadsTheForecast() throws {
        let url = try XCTUnwrap(WorldBrief.weatherURL(latitude: -27.4712, longitude: 153.0251))
        XCTAssertTrue(url.absoluteString.contains("latitude=-27.5&longitude=153.0"), "rounded before it leaves the Mac")
        let json = #"{"timezone":"Australia/Brisbane","daily":{"temperature_2m_max":[27.4],"temperature_2m_min":[17.6],"#
            + #""precipitation_probability_max":[70],"weather_code":[61]},"hourly":{"time":["2026-10-19T13:00","2026-10-19T14:00","#
            + #""2026-10-19T15:00"],"precipitation_probability":[10,20,70]}}"#
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T02:00:00Z")) // 12 pm in Brisbane
        XCTAssertEqual(WorldBrief.weather(Data(json.utf8), now: now), "Weather at home: 18 to 27°. Rain likely from 3 pm (70%).")
        let dry = #"{"daily":{"temperature_2m_max":[25],"temperature_2m_min":[15],"precipitation_probability_max":[5],"weather_code":[1]}}"#
        XCTAssertEqual(WorldBrief.weather(Data(dry.utf8), now: now), "Weather at home: 15 to 25°. No rain expected.")
        XCTAssertNil(WorldBrief.weather(Data("{}".utf8), now: now))
    }

    func testFlightStatusFromTheTracker() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T23:05:00Z")) // 9:05 am
        let flying = Data(#"{"ac":[{"flight":"QFA520  ","alt_baro":34150,"gs":451.2}],"total":1}"#.utf8)
        XCTAssertEqual(
            WorldBrief.flight(flying, number: "QF520", start: start, now: start, calendar: calendar),
            "QF520 is in the air at 34,000 ft."
        )
        let none = Data(#"{"ac":[],"total":0}"#.utf8)
        XCTAssertEqual(
            WorldBrief.flight(none, number: "QF520", start: start, now: start.addingTimeInterval(-3600), calendar: calendar),
            "QF520 is due at 9:05 am and isn't in the air yet."
        )
        XCTAssertEqual(WorldBrief.flightURL(callsign: "qfa520")?.absoluteString, "https://api.adsb.lol/v2/callsign/QFA520")
    }
}

final class WorldSeamlessTests: XCTestCase {
    private func name(_ text: String, last: String? = nil) -> String? {
        switch WorldCommand.parse(text, worldOpen: true, lastPlace: last) {
        case let .action(name, _, _): name
        case let .tool(name, _): name
        case .retarget: "retarget"
        default: nil
        }
    }

    func testTheGlobesOwnControls() {
        XCTAssertEqual(name("zoom in a bit"), "adjust_camera_zoom")
        XCTAssertEqual(name("show the whole world"), "zoom_to_globe")
        XCTAssertEqual(name("tilt down"), "move_camera")
        XCTAssertEqual(name("switch to night vision"), "set_visual_style")
        XCTAssertEqual(name("3D view"), "set_map_stack")
        XCTAssertEqual(name("turn on satellites"), "set_layer_visibility")
        XCTAssertEqual(name("hide the rain radar"), "set_layer_visibility")
        XCTAssertNil(name("turn on cctv"), "cameras go through the planner (#311)")
        XCTAssertEqual(name("show licence plate cameras"), "show_in_gods_eye_view", "no longer declined (#311)")
        guard case let .action(_, arguments, said) = WorldCommand.parse("follow QF1", worldOpen: true) else { return XCTFail("follow") }
        XCTAssertEqual(arguments, .object(["query": .string("QFA1")]))
        XCTAssertEqual(said, "Following QF1.")
        XCTAssertEqual(name("stop following"), "stop_tracking")
        XCTAssertEqual(name("clear the globe"), "clear_annotations")
        XCTAssertNil(WorldCommand.parse("zoom in", worldOpen: false), "only while the globe shows")
        XCTAssertEqual(name("show me flights over Brisbane"), "aircraft_in_area", "a tool, not a layer")
    }

    func testFollowUpsKeepThePlace() {
        XCTAssertEqual(WorldCommand.parse("what about Sydney?", worldOpen: true, lastPlace: "brisbane"), .retarget(place: "sydney"))
        guard case let .tool(tool, arguments) = WorldCommand.parse("now ships there", worldOpen: true, lastPlace: "brisbane") else {
            return XCTFail("ships there")
        }
        XCTAssertEqual(tool, "vessels_in_area")
        XCTAssertEqual(arguments, .object(["area": .object(["place": .string("brisbane")]), "limit": .number(25)]))
        let flights = WorldCommand.parse("flights over Brisbane", worldOpen: true)
        XCTAssertEqual(flights?.place, "brisbane")
        XCTAssertEqual(flights?.retargeted(to: "perth")?.place, "perth")
        XCTAssertNil(WorldCommand.parse("what about tomorrow?", worldOpen: false), "no World follow-up outside the globe")
    }
}

@testable import AegisKit
import XCTest

/// Air quality, disasters, space weather and Bureau warnings around home (ADR-0024). Synthetic data and places only.
final class WorldAlertsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T02:00:00Z")! // 12 pm in Brisbane

    func testAirAtHome() throws {
        let url = try XCTUnwrap(WorldAlerts.airURL(latitude: -27.4712, longitude: 153.0251))
        XCTAssertTrue(url.absoluteString.contains("latitude=-27.5&longitude=153.0&current=us_aqi&hourly=us_aqi"), "rounded")
        let json = #"{"timezone":"Australia/Brisbane","current":{"us_aqi":39},"hourly":{"time":["2026-10-19T11:00","#
            + #""2026-10-19T15:00","2026-10-19T16:00"],"us_aqi":[160,72,64]}}"#
        XCTAssertEqual(
            WorldAlerts.air(Data(json.utf8), now: now, locale: Locale(identifier: "en_AU")),
            "Air at home: good (AQI 39). Moderate around 3 pm (AQI 72).",
            "only the hours still to come"
        )
        XCTAssertEqual(WorldAlerts.air(Data(#"{"current":{"us_aqi":151}}"#.utf8), now: now), "Air at home: unhealthy (AQI 151).")
        XCTAssertNil(WorldAlerts.air(Data("{}".utf8), now: now))
        XCTAssertEqual(WorldAlerts.airBand(320).words, "hazardous")
    }

    func testEruptionsAndDisastersInTheRegion() throws {
        let url = try XCTUnwrap(WorldAlerts.disastersURL(now: now))
        XCTAssertEqual(
            url.absoluteString,
            "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?eventlist=EQ;TC;FL;VO;WF;DR&fromDate=2026-09-19&toDate=2026-10-19",
            "nothing about home is sent"
        )
        func event(
            _ type: String,
            id: Int,
            _ name: String,
            country: String = "Exampleland",
            lon: Double,
            lat: Double,
            level: String,
            date: String
        )
            -> String
        {
            #"{"geometry":{"type":"Point","coordinates":["# + "\(lon),\(lat)" + #"]},"properties":{"eventtype":""# + type
                + #"","eventid":\#(id),"eventname":""# + name + #"","country":""# + country + #"","alertlevel":""# + level
                + #"","todate":""# + date + #""}}"#
        }
        let json = #"{"type":"FeatureCollection","features":["# + [
            event("VO", id: 1, "Near Peak", lon: 150.0, lat: -20.0, level: "Orange", date: "2026-10-17T05:00:00"),
            event("VO", id: 2, "Far Peak", lon: -100.0, lat: 20.0, level: "Red", date: "2026-10-18T05:00:00"),
            event("VO", id: 3, "Old Peak", lon: 152.0, lat: -25.0, level: "Red", date: "2026-10-01T05:00:00"),
            event("TC", id: 4, "EXAMPLE-26", lon: 160.0, lat: -18.0, level: "Red", date: "2026-10-18T06:00:00"),
            event(
                "DR",
                id: 5,
                "Region-2026",
                country: "Aland, Bland, Cland, Dland",
                lon: 140.0,
                lat: -30.0,
                level: "Orange",
                date: "2026-10-18T00:00:00"
            ),
            event("EQ", id: 6, "", lon: 155.0, lat: -28.0, level: "Orange", date: "2026-10-18T03:00:00"),
            event("XX", id: 7, "Unknown", lon: 153.0, lat: -27.5, level: "Red", date: "2026-10-18T03:00:00"),
        ].joined(separator: ",") + "]}"
        let home = (latitude: -27.5, longitude: 153.0)
        let locale = Locale(identifier: "en_AU")
        let week = WorldAlerts.disasters(
            Data(json.utf8), latitude: home.latitude, longitude: home.longitude, now: now, days: 7, locale: locale
        )
        XCTAssertEqual(week?.map(\.text), [
            "Exampleland: an orange-alert earthquake on 18 October, 200 km from home.",
            "Near Peak, Exampleland: an orange-alert eruption on 17 October, 900 km from home.",
            "EXAMPLE-26, Exampleland: a red-alert tropical cyclone on 18 October, 1,300 km from home.",
            "Aland, Bland and 2 more: an orange-alert drought on 18 October, 1,300 km from home.",
        ], "nearest first; unknown types, far and old ones left out")
        XCTAssertEqual(week?.first?.key, "EQ-6-Orange")
        let eruptions = WorldAlerts.disasters(
            Data(json.utf8), only: "VO", latitude: home.latitude, longitude: home.longitude, now: now, days: 30
        )
        XCTAssertEqual(eruptions?.map { $0.text.prefix(8) }, ["Old Peak", "Near Pea"], "eruptions only, for the volcano question")
        XCTAssertEqual(WorldAlerts.disasters(Data(), latitude: 0, longitude: 0, now: now, days: 7), [], "GDACS's 204: none")
        XCTAssertNil(WorldAlerts.disasters(Data("<html>".utf8), latitude: 0, longitude: 0, now: now, days: 7))
    }

    func testSpaceWeatherAndAurora() throws {
        XCTAssertFalse(WorldAlerts.spaceURL.absoluteString.contains("?"), "nothing about home is sent")
        func steps(_ kps: [(String, Double)]) -> Data {
            Data(("[" + kps.map { #"{"time_tag":""# + $0.0 + #"","kp":\#($0.1),"observed":"predicted","noaa_scale":null}"# }
                    .joined(separator: ",") + "]").utf8)
        }
        let brisbane = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let locale = Locale(identifier: "en_AU")
        let storm = steps([
            ("2026-10-18T21:00:00", 7.67), // past
            ("2026-10-19T00:00:00", 3.0), // under way at 2 am UTC
            ("2026-10-19T15:00:00", 6.33), // 1 am in Brisbane
            ("2026-10-19T18:00:00", 6.0),
            ("2026-10-21T00:00:00", 9.0), // more than a day ahead
        ])
        // A synthetic home far south (geomagnetic latitude about 50°) and one further north (about 34°).
        let south = try XCTUnwrap(WorldAlerts.space(storm, latitude: -43.0, longitude: 147.0, now: now, timeZone: brisbane, locale: locale))
        XCTAssertEqual(
            south.answer,
            "A moderate geomagnetic storm (G2) is forecast around 1 am. Aurora may be visible from home looking south, away from city lights."
        )
        XCTAssertEqual(south.alert?.key, "space-G2-2026-10-19")
        let north = try XCTUnwrap(WorldAlerts.space(storm, latitude: -27.5, longitude: 153.0, now: now, timeZone: brisbane, locale: locale))
        XCTAssertEqual(north.answer, "A moderate geomagnetic storm (G2) is forecast around 1 am. Aurora isn't likely to be seen from home.")
        XCTAssertNil(north.alert, "not in the brief: neither visible nor strong")
        let strong = steps([("2026-10-19T00:00:00", 7.0)])
        XCTAssertEqual(
            WorldAlerts.space(strong, latitude: -27.5, longitude: 153.0, now: now)?.alert?.text,
            "A strong geomagnetic storm (G3) is under way. Aurora isn't likely to be seen from home.",
            "a strong storm is in the brief anyway"
        )
        let quiet = try XCTUnwrap(WorldAlerts.space(steps([("2026-10-19T03:00:00", 2.33)]), latitude: -43.0, longitude: 147.0, now: now))
        XCTAssertEqual(
            quiet.answer,
            "No geomagnetic storm is forecast for the next day (Kp 2 at most). Aurora isn't likely to be seen from home."
        )
        XCTAssertNil(quiet.alert)
        XCTAssertNil(WorldAlerts.space(Data("[]".utf8), latitude: 0, longitude: 0, now: now), "no steps ahead")
        XCTAssertNil(WorldAlerts.space(Data("{}".utf8), latitude: 0, longitude: 0, now: now))
        XCTAssertEqual(WorldAlerts.geomagneticLatitude(80.8, -72.6), 90, accuracy: 0.001)
    }

    func testOnlyWhatsNewStaysInTheBrief() {
        let cyclone = WorldAlerts.Alert(key: "TC-4-Orange", text: "cyclone"), quake = WorldAlerts.Alert(key: "EQ-6-Orange", text: "quake")
        let first = WorldAlerts.fresh([cyclone], firstSeen: ["old": now.addingTimeInterval(-31 * 86400)], now: now)
        XCTAssertEqual(first.alerts, [cyclone])
        XCTAssertEqual(first.firstSeen, ["TC-4-Orange": now], "forgotten after 30 days")
        let later = now.addingTimeInterval(11 * 3600)
        XCTAssertEqual(WorldAlerts.fresh([cyclone, quake], firstSeen: first.firstSeen, now: later).alerts, [cyclone, quake])
        let nextDay = now.addingTimeInterval(13 * 3600)
        let escalated = WorldAlerts.Alert(key: "TC-4-Red", text: "cyclone, now red")
        XCTAssertEqual(
            WorldAlerts.fresh([cyclone, escalated], firstSeen: first.firstSeen, now: nextDay).alerts,
            [escalated],
            "seen ones drop out after 12 hours; an escalation is new"
        )
    }

    func testBureauWarningsForHome() throws {
        let towns = dbf(fields: [("AAC", 10), ("STATE_CODE", 4), ("LAT", 8), ("LON", 8), ("AAC_PW", 10), ("AAC_FW", 10)], rows: [
            ["QLD_PT001", "QLD", "-27.50", "153.00", "QLD_PW015", "QLD_FW015"],
            ["QLD_PT002", "QLD", "-27.55", "153.05", "QLD_PW014", "QLD_FW015"], // 8 km: home may be near the edge
            ["QLD_PT003", "QLD", "-25.00", "150.00", "QLD_PW009", "QLD_FW009"],
            ["NSW_PT001", "NSW", "-33.90", "151.20", "NSW_PW005", "NSW_FW004"],
        ])
        let gauges = dbf(fields: [("AAC", 10), ("LAT", 8), ("LON", 8)], rows: [
            ["QLD_RS020", "-27.60", "153.10"], ["QLD_RS099", "-26.00", "152.00"],
        ])
        let area = try XCTUnwrap(WorldAlerts.bureauArea(towns: towns, gauges: gauges, latitude: -27.51, longitude: 153.01))
        XCTAssertEqual(area.prefixes, ["IDQ"])
        XCTAssertEqual(area.codes, ["QLD_PW015", "QLD_PW014", "QLD_FW015", "QLD_RS020"])
        XCTAssertNil(WorldAlerts.bureauArea(towns: towns, gauges: gauges, latitude: 51.5, longitude: 0), "not in Australia")
        XCTAssertNil(WorldAlerts.bureauArea(towns: Data("not a table".utf8), gauges: gauges, latitude: -27.5, longitude: 153))

        let listing = "IDQ21033.cap.xml\nIDN21033.cap.xml\nIDQ20807.cap.xml\nIDQ21033.xml\n../IDQ00001.cap.xml\nIDQ1.cap.xml;x\n"
        XCTAssertEqual(WorldAlerts.bureauFiles(listing: listing, area: area), ["IDQ21033.cap.xml", "IDQ20807.cap.xml"])

        let cap = alert(parts: [
            ("Severe Thunderstorm Warning for Example Coast &amp; Ranges", "2026-10-19T05:00:00+00:00", ["QLD_PW015", "QLD_PW016"]),
            ("Severe Thunderstorm Warning for Far Example Plains", "2026-10-19T05:00:00+00:00", ["QLD_PW009"]),
            ("Minor Flood Warning for Example Creek", "2026-10-18T05:00:00+00:00", ["QLD_RS020"]), // expired
            ("Moderate Flood Warning for Example Creek", "2026-10-20T05:00:00+00:00", ["QLD_RC001", "QLD_RS020"]),
        ])
        XCTAssertEqual(WorldAlerts.bureauWarnings(Data(cap.utf8), area: area, now: now), [
            "Severe Thunderstorm Warning for Example Coast & Ranges", "Moderate Flood Warning for Example Creek",
        ])
        let cancelled = alert(parts: [("Cancellation of Severe Thunderstorm Warning", "2026-10-19T05:00:00+00:00", ["QLD_PW015"])])
        XCTAssertEqual(WorldAlerts.bureauWarnings(Data(cancelled.utf8), area: area, now: now), [])
        let test = cap.replacingOccurrences(of: "<status>Actual</status>", with: "<status>Test</status>")
        XCTAssertEqual(WorldAlerts.bureauWarnings(Data(test.utf8), area: area, now: now), [])
    }

    func testOwnerQuestions() {
        func parse(_ text: String) -> WorldCommand? {
            WorldCommand.parse(text, worldOpen: false, homeCity: "Brisbane")
        }
        for (text, kind) in [
            ("How's the air today?", WorldAlerts.Kind.air), ("what's the air quality like at the moment", .air),
            ("Is it smoky?", .air), ("Any volcano alerts?", .volcanoes), ("Are any volcanoes erupting near me?", .volcanoes),
            ("Are there any weather warnings near me?", .warnings), ("any flood warnings", .warnings),
            ("Hey Aegis, any severe weather?", .warnings), ("Any warnings in place for my area?", .warnings),
            ("Any aurora tonight?", .space), ("Can I see the southern lights from home?", .space), ("space weather", .space),
            ("Is there a geomagnetic storm warning?", .space), ("Any disasters near me?", .disasters),
            ("what natural disasters are happening", .disasters),
        ] {
            XCTAssertEqual(parse(text), .alerts(kind), text)
        }
        XCTAssertEqual(
            parse("storm warnings for Sydney"),
            .declined("I can only check the Bureau of Meteorology's warnings for home for now.")
        )
        XCTAssertEqual(parse("air quality in Delhi"), .declined("I can only check the air at home for now."))
        XCTAssertEqual(parse("aurora in Tasmania"), .declined("I can only check space weather and aurora from home for now."))
        XCTAssertNil(parse("How do volcanoes form?"), "a general question, for the conversation")
        XCTAssertNil(parse("Disaster movies from the nineties"))
        guard case .tool("aircraft_in_area", _) = parse("flights over Aurora") else { return XCTFail("Aurora, the city") }
        XCTAssertNil(parse("Give me a smoky barbecue sauce recipe"))
        guard case .tool("get_cyclones", _) = parse("any cyclones?") else { return XCTFail("cyclones stay on the globe") }
    }

    /// A dBase III table, as the Bureau's map files are.
    private func dbf(fields: [(String, Int)], rows: [[String]]) -> Data {
        let length = 1 + fields.reduce(0) { $0 + $1.1 }, header = 32 + 32 * fields.count + 1
        var bytes: [UInt8] = [3, 126, 1, 1]
        bytes += withUnsafeBytes(of: UInt32(rows.count).littleEndian, Array.init)
        bytes += withUnsafeBytes(of: UInt16(header).littleEndian, Array.init)
        bytes += withUnsafeBytes(of: UInt16(length).littleEndian, Array.init)
        bytes += [UInt8](repeating: 0, count: 20)
        for (name, width) in fields {
            var field = [UInt8](name.utf8) + [UInt8](repeating: 0, count: 11 - name.utf8.count)
            field += [UInt8(ascii: "C"), 0, 0, 0, 0, UInt8(width)] + [UInt8](repeating: 0, count: 15)
            bytes += field
        }
        bytes.append(0x0D)
        for row in rows {
            bytes.append(0x20)
            for (value, field) in zip(row, fields) {
                bytes += [UInt8](value.utf8) + [UInt8](repeating: 0x20, count: field.1 - value.utf8.count)
            }
        }
        return Data(bytes + [0x1A])
    }

    /// A CAP warning file like the Bureau's: one <info> part per headline.
    private func alert(parts: [(String, String, [String])]) -> String {
        let infos = parts.map { headline, expires, codes in
            "<info><event>Thunderstorm</event><expires>\(expires)</expires><headline>\(headline)</headline><area><areaDesc>Example</areaDesc>"
                + codes.map { "<geocode><valueName>AMOC-AreaCode</valueName><value>\($0)</value></geocode>" }.joined() + "</area></info>"
        }
        return #"<?xml version="1.0" encoding="UTF-8"?><alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>example</identifier>"#
            + "<status>Actual</status><msgType>Update</msgType>" + infos.joined() + "</alert>"
    }
}

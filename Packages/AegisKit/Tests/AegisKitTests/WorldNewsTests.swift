@testable import AegisKit
import XCTest

/// World headlines on the globe (#116). Synthetic feeds and a synthetic time zone table only.
final class WorldNewsTests: XCTestCase {
    private let zones = """
    # comment\tline
    AU\t-3133+15905\tAustralia/Lord_Howe\tLord Howe Island
    AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)
    JP\t+353916+1394441\tAsia/Tokyo
    KP\t+3901+12545\tAsia/Pyongyang
    KR\t+3733+12658\tAsia/Seoul
    UA\t+4457+03406\tEurope/Simferopol\tCrimea
    UA\t+5026+03031\tEurope/Kyiv\tmost of Ukraine
    IL\t+314650+0351326\tAsia/Jerusalem
    TR\t+4101+02858\tEurope/Istanbul
    CD\t-0418+01518\tAfrica/Kinshasa\tDem. Rep. of Congo (west)
    XX\tnot-a-point\tNowhere/Else
    """

    func testFeedTitles() {
        let rss = """
        <rss><channel><title>Example News</title>
        <item><title><![CDATA[Example ministers meet in Japan]]></title></item>
        <item><title>Rival plans &#8211; and a &quot;deal&quot; &amp; more</title></item>
        <item rdf:about="x"><title> <![CDATA[<b>Bold</b> claim   in  Ukraine]]> </title></item>
        <item><description>no title</description></item>
        </channel></rss>
        """
        XCTAssertEqual(WorldNews.headlines(Data(rss.utf8)), [
            "Example ministers meet in Japan", "Rival plans – and a \"deal\" & more", "b Bold /b claim in Ukraine",
        ], "items only, references decoded, no angle brackets for the globe")
        XCTAssertEqual(WorldNews.headlines(Data("<html>".utf8)), [])
    }

    func testCountryPoints() throws {
        let points = WorldNews.countries(zoneTab: Data(zones.utf8))
        let sydney = try XCTUnwrap(points["AU"])
        XCTAssertEqual(sydney.latitude, -33.867, accuracy: 0.001, "the capital's zone, not the outlying first one")
        XCTAssertEqual(sydney.longitude, 151.217, accuracy: 0.001)
        let tokyo = try XCTUnwrap(points["JP"])
        XCTAssertEqual(tokyo.latitude, 35.654, accuracy: 0.001, "with seconds")
        XCTAssertEqual(tokyo.longitude, 139.745, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points["UA"]).latitude, 50.433, accuracy: 0.001)
        XCTAssertNil(points["XX"])
    }

    func testPinsAtTheCountriesHeadlinesName() {
        let points = WorldNews.countries(zoneTab: Data(zones.utf8))
        let pins = WorldNews.pins([
            "North Korea tests an example rocket",
            "Storm hits South Korean coast",
            "Example talks: Israeli and Ukrainian envoys meet",
            "A second story about Japan",
            "Another Japan story",
            "Cooking turkey for a crowd",
            "Rebels advance in DR Congo",
            "A story that names no country",
        ], countries: points)
        XCTAssertEqual(pins.map(\.country), ["North Korea", "South Korea", "Israel", "Japan", "DR Congo"])
        XCTAssertEqual(pins.first?.headline, "North Korea tests an example rocket")
        XCTAssertEqual(pins.last?.latitude ?? 0, -4.3, accuracy: 0.01)
        let many = WorldNews.pins((0 ..< 40).map { "Story \($0) in Japan" }, countries: points)
        XCTAssertEqual(many.count, 1, "one pin per country")
    }

    func testGlobeViewAndAnswer() {
        let pins = [
            WorldNews.Pin(headline: "Example talks in Japan", country: "Japan", latitude: 35.0, longitude: 139.0),
            WorldNews.Pin(headline: "Example vote in Ukraine?", country: "Ukraine", latitude: 50.0, longitude: 30.0),
        ]
        guard case let .object(view) = WorldNews.view(pins), case let .array(annotations)? = view["annotations"] else {
            return XCTFail("a view")
        }
        XCTAssertEqual(annotations.first, .object([
            "type": .string("pin"), "latitude": .number(35), "longitude": .number(139), "label": .string("Example talks in Japan"),
            "color": .string("amber"),
        ]))
        XCTAssertEqual(view["layers"], .array([]))
        guard case let .object(camera)? = view["camera"] else { return XCTFail("a camera") }
        XCTAssertEqual(camera["lon"], .number(84.5))
        XCTAssertEqual(
            WorldNews.answer(pins),
            "Here are 2 world headlines on the globe. Japan: Example talks in Japan. Ukraine: Example vote in Ukraine?"
        )
        XCTAssertEqual(WorldNews.answer([]), "None of the latest world headlines names a country I can pin.")
    }

    func testOwnerAsks() {
        for text in [
            "What's happening in the world?",
            "world news",
            "Show the headlines on the globe",
            "Aegis, what's the latest news",
            "read me today's headlines",
        ] {
            XCTAssertEqual(WorldCommand.parse(text, worldOpen: false), .headlines, text)
        }
        XCTAssertNotEqual(WorldCommand.parse("any news from the builder?", worldOpen: false), .headlines)
    }
}

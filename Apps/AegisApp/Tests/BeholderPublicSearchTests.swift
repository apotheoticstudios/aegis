@testable import Aegis
import XCTest

final class BeholderPublicSearchTests: XCTestCase {
    private typealias Search = BeholderPublicSearch

    func testFixedDestinationsAndExactSeedOnly() throws {
        let input = Search.Input(value: "Example Alex", kind: .name, region: .international)
        let plan = try XCTUnwrap(Search.prepare(input, service: .duckDuckGo))
        let url = try XCTUnwrap(URLComponents(url: plan.destination, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "duckduckgo.com"); XCTAssertEqual(url.path, "/")
        XCTAssertEqual(url.queryItems, [.init(name: "q", value: "\"Example Alex\"")])
        XCTAssertNil(url.user); XCTAssertNil(url.password); XCTAssertNil(url.fragment); XCTAssertNil(url.port)
        let github = try XCTUnwrap(Search.prepare(input, service: .github))
        XCTAssertEqual(github.query, "\"Example Alex\" in:name")
        XCTAssertEqual(
            URLComponents(url: github.destination, resolvingAgainstBaseURL: false)?.queryItems,
            [.init(name: "type", value: "users"), .init(name: "q", value: github.query)]
        )
    }

    func testPlusAddressesAndCountryCodesSurviveBrowserFormDecoding() throws {
        for (value, kind, region, expected) in [
            (
                "example+tag@EXAMPLE.COM",
                BeholderCaseSearch.Kind.email,
                BeholderQueryPlanner.PhoneRegion.international,
                "example+tag@example.com"
            ),
            ("tel:61400000001", .phone, .australia, "+61400000001"),
        ] {
            let plan = try XCTUnwrap(Search.prepare(.init(value: value, kind: kind, region: region), service: .duckDuckGo))
            XCTAssertEqual(plan.query, "\"" + expected + "\"")
            XCTAssertTrue(plan.destination.absoluteString.contains("%2B"))
            XCTAssertEqual(URLComponents(url: plan.destination, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, plan.query)
        }
        let email = try XCTUnwrap(Search.prepare(
            .init(value: "example+tag@example.com", kind: .email, region: .international),
            service: .github
        ))
        XCTAssertEqual(email.query, "\"example+tag@example.com\" in:email")
    }

    func testUnsupportedKindsAndUnsafeInputCannotBecomePublicQueries() {
        for kind in [BeholderCaseSearch.Kind.phone, .ip] {
            XCTAssertNil(Search.prepare(
                .init(value: kind == .phone ? "+61400000001" : "203.0.113.1", kind: kind, region: .international),
                service: .github
            ))
        }
        XCTAssertNil(Search.prepare(.init(value: "203.0.113.1", kind: .ip, region: .international), service: .duckDuckGo))
        for value in ["Example\" OR secret", "Example\nAlex", String(repeating: "a", count: 513)] {
            XCTAssertNil(Search.prepare(.init(value: value, kind: .name, region: .international), service: .duckDuckGo))
        }
        XCTAssertNil(Search.prepare(
            .init(value: "example@example.com?redirect=other", kind: .email, region: .international),
            service: .duckDuckGo
        ))
    }

    func testServiceChoiceIsPinnedToExactInputBeforeUIChangeCallbacks() {
        let original = Search.Input(value: "Example Alex", kind: .name, region: .international)
        let selection = Search.Selection(service: .duckDuckGo, input: original)
        XCTAssertNotNil(selection.plan(for: original))
        for other in [
            Search.Input(value: "Example Sam", kind: .name, region: .international),
            .init(value: "Example Alex ", kind: .name, region: .international),
            .init(value: "Example Alex", kind: .username, region: .international),
            .init(value: "Example Alex", kind: .name, region: .australia),
        ] {
            XCTAssertNil(selection.plan(for: other))
        }
    }

    func testServiceChoicesMatchSupportedInputTypesAndUsernameRejectsOtherIdentifiers() {
        for kind in BeholderCaseSearch.Kind.allCases {
            let services = Search.Service.allCases.filter { $0.supports(kind) }
            switch kind {
            case .username, .name, .email: XCTAssertEqual(services, [.duckDuckGo, .github])
            case .phone: XCTAssertEqual(services, [.duckDuckGo])
            case .ip: XCTAssertTrue(services.isEmpty)
            }
        }
        for value in ["0400000001", "61400000001", "example@example.com", "203.0.113.1"] {
            for service in Search.Service.allCases {
                XCTAssertNil(Search.prepare(.init(value: value, kind: .username, region: .international), service: service))
            }
        }
    }

    @MainActor func testImportedOrRestoredInputIsNotMarkedAsOwnerTyped() {
        let model = BeholderModel()
        model.query = "ExampleAlex"
        let discovery = BeholderDiscovery(model)
        XCTAssertFalse(discovery.ownerTypedInput)
        discovery.query = "ExampleOther"
        XCTAssertTrue(discovery.ownerTypedInput)
        discovery.kind = .email
        XCTAssertFalse(discovery.ownerTypedInput); XCTAssertEqual(discovery.query, "")
        discovery.query = "example@example.com"
        XCTAssertTrue(discovery.ownerTypedInput)
        discovery.resetAfterImport()
        XCTAssertFalse(discovery.ownerTypedInput); XCTAssertEqual(discovery.query, "")
    }
}

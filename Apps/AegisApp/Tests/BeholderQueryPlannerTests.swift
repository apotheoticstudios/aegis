@testable import Aegis
import XCTest

final class BeholderQueryPlannerTests: XCTestCase {
    private typealias Planner = BeholderQueryPlanner

    func testQuotedQueriesWithExplicitOperatorsOnly() throws {
        let plan = try Planner.build(input: " @ExampleAlex ", kind: .username, scope: "EXAMPLE.COM", document: .pdf).get()
        XCTAssertEqual(plan.seed, "ExampleAlex")
        XCTAssertEqual(plan.query, "\"ExampleAlex\" site:example.com filetype:pdf")
        XCTAssertEqual(plan.scope, "example.com")
        XCTAssertEqual(plan, try Planner.build(input: "@ExampleAlex", kind: .username, scope: "example.com", document: .pdf).get())
        XCTAssertTrue(plan.notes.contains(where: { $0.contains("subdomains") }))
    }

    func testNamesAndEmailKeepTheirMeaning() throws {
        XCTAssertEqual(try Planner.build(input: "Example   Alex", kind: .name).get().query, "\"Example Alex\"")
        XCTAssertEqual(try Planner.build(input: "Example José", kind: .name).get().seed, "Example José")
        let email = try Planner.build(input: "mailto:Example+work@EXAMPLE.COM", kind: .email).get()
        XCTAssertEqual(email.query, "\"Example+work@example.com\"")
        XCTAssertNotEqual(email.seed, try Planner.build(input: "Example@example.com", kind: .email).get().seed)
        XCTAssertEqual(try Planner.build(input: "EXAMPLE.COM", kind: .domain).get().query, "\"example.com\"")
    }

    func testPhoneFormatsRequireExplicitRegionAndDoNotClaimValidity() throws {
        for value in ["0400 000 001", "(04) 0000 0001", "tel:0400-000-001", "+61 400 000 001"] {
            let plan = try Planner.build(input: value, kind: .phone, region: .australia).get()
            XCTAssertEqual(plan.seed, "+61400000001")
            XCTAssertTrue(plan.notes.contains(where: { $0.contains("have not been checked") }))
        }
        XCTAssertEqual(try Planner.build(input: "+61.400.000.002", kind: .phone).get().query, "\"+61400000002\"")
        for value in ["0400000001", "61400000001", "12345", "KFC Example", "+00000001", "+61400000001 ext 2", "+61+400000001"] {
            XCTAssertThrowsError(try Planner.build(input: value, kind: .phone).get(), value)
        }
    }

    func testRejectsOperatorInjectionAndHiddenTextInEveryMode() {
        for kind in Planner.Kind.allCases {
            for value in [
                "Example\" OR site:example.com",
                "Example\nAlex",
                "Example\tAlex",
                "Example\u{2028}Alex",
                "Example\u{2029}Alex",
                "Example\u{0085}Alex",
                "Example\u{200B}Alex",
                "Example\u{202E}Alex",
                String(repeating: "E", count: 513),
            ] {
                XCTAssertThrowsError(try Planner.build(input: value, kind: kind).get(), "\(kind): unsafe input")
            }
        }
        for scope in [
            "example.com OR example.org",
            "https://example.com",
            "example.com/path",
            "example.com:443",
            "example.com@other.example",
            "-example.com",
            "example..com",
            ".example.com",
            "example.com.",
            "127.0.0.1",
            "example.com\u{200B}",
            String(repeating: "e", count: 64) + ".com",
        ] {
            XCTAssertThrowsError(try Planner.build(input: "ExampleAlex", kind: .username, scope: scope).get())
        }
    }

    func testInvalidValuesDoNotProducePlans() {
        let cases: [(Planner.Kind, [String])] = [
            (.username, ["", "https://example.com", "a@example.com", "Example..Alex"]),
            (.name, ["", "--", "Example:Alex", "Example/Alex"]),
            (.email, ["Example@", "@example.com", "Example@@example.com", "Example..Alex@example.com", "Example.@example.com"]),
            (.domain, ["example", "example.com/path", "example.com?x=1"]),
            (.phone, ["", "()", "+1", "+" + String(repeating: "1", count: 16)]),
        ]
        for (kind, values) in cases {
            for value in values {
                XCTAssertThrowsError(try Planner.build(input: value, kind: kind).get())
            }
        }
    }

    @MainActor func testPlanningDoesNotChangeLookupStateOrStartRequests() throws {
        let model = BeholderModel()
        model.query = "ExampleOriginal"
        let selected = model.selected
        _ = try Planner.build(input: "ExampleOther", kind: .name, scope: "example.com").get()
        XCTAssertEqual(model.query, "ExampleOriginal")
        XCTAssertEqual(model.selected, selected)
        XCTAssertTrue(model.findings.isEmpty)
        XCTAssertFalse(model.searching)
    }
}

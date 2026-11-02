@testable import Aegis
import XCTest

final class BeholderGitHubDiscoveryTests: XCTestCase {
    private typealias Discovery = BeholderGitHubDiscovery
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    func testExactRequestShapeAndPlusEncoding() throws {
        for (value, kind, expected) in [
            ("Example Alex", Discovery.Kind.name, "\"Example Alex\" in:name type:user"),
            ("example+tag@EXAMPLE.COM", .email, "\"example+tag@example.com\" in:email type:user"),
        ] {
            let request = try XCTUnwrap(Discovery.prepare(.init(value: value, kind: kind)))
            let parts = try XCTUnwrap(URLComponents(url: request.endpoint, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.scheme, "https"); XCTAssertEqual(parts.host, "api.github.com"); XCTAssertEqual(parts.path, "/search/users")
            XCTAssertEqual(
                parts.queryItems,
                [.init(name: "q", value: expected), .init(name: "per_page", value: "20"), .init(name: "page", value: "1")]
            )
            XCTAssertTrue(Discovery.permits(request.endpoint))
            if kind == .email {
                XCTAssertTrue(request.endpoint.absoluteString.contains("%2B"))
            }
            XCTAssertNil(parts.user); XCTAssertNil(parts.password); XCTAssertNil(parts.fragment)
        }
        for value in ["Example\" OR private", "Example\nAlex", String(repeating: "a", count: 513)] {
            XCTAssertNil(Discovery.prepare(.init(value: value, kind: .name)))
        }
        for value in ["example@example.com?other=x", "example@example.com\n"] {
            XCTAssertNil(Discovery.prepare(.init(value: value, kind: .email)))
        }
    }

    func testAlternateDestinationsParametersAndEncodingAreRejected() throws {
        let request = try XCTUnwrap(Discovery.prepare(.init(value: "Example Alex", kind: .name)))
        let original = request.endpoint.absoluteString
        for value in [
            original.replacingOccurrences(of: "api.github.com", with: "example.com"),
            original.replacingOccurrences(of: "https:", with: "http:"),
            original + "&page=2",
            original + "&sort=followers",
            original + "#hidden",
            original.replacingOccurrences(of: "page=1", with: "page=2"),
        ] {
            XCTAssertFalse(try Discovery.permits(XCTUnwrap(URL(string: value))))
        }
        XCTAssertFalse(BeholderProvider.permits(request.endpoint), "Normal username transport must not acquire this new endpoint")
    }

    func testPublicUserHitsAreBoundedAndReturnedLinksAreIgnored() throws {
        let request = try XCTUnwrap(Discovery.prepare(.init(value: "Example Alex", kind: .name)))
        let items = (0 ..< 25).map { [
            "login": "Example-\($0)",
            "type": "User",
            "url": "https://example.com/ignored",
            "avatar_url": "https://example.com/ignored",
            "html_url": "https://example.com/ignored",
        ] }
        let payload = try payload(total: 25, incomplete: true, items: items)
        let page = try Discovery.parse(payload, request: request, now: date).get()
        XCTAssertEqual(page.hits.count, 20); XCTAssertEqual(page.hits.first?.login, "Example-0")
        XCTAssertEqual(page.total, 25); XCTAssertTrue(page.incomplete); XCTAssertEqual(page.checkedAt, date)
        for item in [
            ["login": "../private", "type": "User"],
            ["login": "Example", "type": "Organization"],
            ["login": "Example", "type": "Bot"],
            ["login": "Example@example.com", "type": "User"],
        ] {
            XCTAssertEqual(
                try Discovery.parse(self.payload(total: 1, incomplete: false, items: [item]), request: request, now: date),
                .failure(.response)
            )
        }
        let duplicate = try self.payload(
            total: 2,
            incomplete: false,
            items: [["login": "Example", "type": "User"], ["login": "example", "type": "User"]]
        )
        XCTAssertEqual(try Discovery.parse(duplicate, request: request, now: date).get().hits.count, 1)
    }

    func testMalformedPartialAndRateLimitedResponsesNeverClaimAbsence() throws {
        let request = try XCTUnwrap(Discovery.prepare(.init(value: "Example Alex", kind: .name)))
        let totals: [Any] = [true, -1, 0.5, 1_000_000_001]
        for total in totals {
            XCTAssertEqual(
                try Discovery.parse(payload(total: total, incomplete: false, items: []), request: request, now: date),
                .failure(.response)
            )
        }
        XCTAssertEqual(try Discovery.parse(payload(total: 0, incomplete: 1, items: []), request: request, now: date), .failure(.response))
        for status in [403, 429] {
            XCTAssertEqual(Discovery.parse(.init(data: Data(), status: status), request: request, now: date), .failure(.limited))
        }
        XCTAssertEqual(Discovery.parse(.init(data: Data(), status: 404), request: request, now: date), .failure(.unavailable))
        XCTAssertEqual(
            Discovery
                .parse(
                    .init(data: Data(repeating: 32, count: BeholderWebTransport.byteLimit + 1), status: 200),
                    request: request,
                    now: date
                ),
            .failure(.response)
        )
    }

    func testEmailContainmentIsNotPresentedAsAnExactProfileMatch() throws {
        let request = try XCTUnwrap(Discovery.prepare(.init(value: "example+tag@example.com", kind: .email)))
        var finding = BeholderFinding(provider: .github, status: .candidate)
        XCTAssertEqual(Discovery.compareEmail(finding, request: request), .unavailable)
        finding.fields["Public email"] = "other-example+tag@example.com"
        XCTAssertEqual(Discovery.compareEmail(finding, request: request), .different)
        finding.fields["Public email"] = "Example+tag@example.com"
        XCTAssertEqual(Discovery.compareEmail(finding, request: request), .caseVariant)
        finding.fields["Public email"] = "example+tag@example.com"
        XCTAssertEqual(Discovery.compareEmail(finding, request: request), .exact)
        finding.fields["Public email"] = "example@example.com"
        XCTAssertEqual(Discovery.compareEmail(finding, request: request), .different)
    }

    @MainActor func testOneSearchThenOneExplicitInspectionAndExportIsolation() async throws {
        let transport = GitHubDiscoveryFixtureTransport(), model = BeholderModel()
        let research = BeholderGitHubResearch(client: BeholderGitHubDiscoveryClient(transport: transport))
        research.value = "Example Unlisted"
        research.search()
        research.inspect(.init(login: "ExampleAlex"), into: model)
        research.chooseGitHub()
        let before = await transport.urls
        XCTAssertTrue(before.isEmpty)
        research.search()
        try await finish { research.searching }
        let hits = try XCTUnwrap(research.page?.hits)
        let searched = await transport.urls
        XCTAssertEqual(searched.count, 1); XCTAssertEqual(searched[0].path, "/search/users")
        XCTAssertTrue(model.correlation.accounts.isEmpty)
        XCTAssertFalse(try String(decoding: model.export(), as: UTF8.self).contains("Example Unlisted"))
        research.inspect(.init(login: "ExampleUnreturned"), into: model)
        let unchanged = await transport.urls
        XCTAssertEqual(unchanged.count, 1)
        try research.inspect(XCTUnwrap(hits.first), into: model)
        try await finish { research.inspecting != nil }
        let inspected = await transport.urls
        XCTAssertEqual(inspected.count, 2); XCTAssertEqual(inspected[1], BeholderProvider.github.endpoint("ExampleAlex"))
        XCTAssertEqual(model.correlation.accounts.count, 1)
        XCTAssertTrue(model.people.people.isEmpty, "Inspection cannot create or identify a person")
        let exported = try model.export()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("Example Unlisted"))
        XCTAssertEqual(try BeholderCaseFile.decode(exported).correlation.accounts.count, 1)
        research.value = "Example New"
        XCTAssertNil(research.prepared); XCTAssertNil(research.page); XCTAssertNil(research.inspected)
        research.reset()
        let final = await transport.urls
        XCTAssertEqual(final.count, 2)
    }

    func testForgedRequestCannotReachTheTransport() async throws {
        let transport = GitHubDiscoveryFixtureTransport(), client = BeholderGitHubDiscoveryClient(transport: transport)
        let request = try XCTUnwrap(Discovery.prepare(.init(value: "Example Alex", kind: .name)))
        let forged = try Discovery.Request(
            input: request.input,
            seed: request.seed,
            query: request.query,
            endpoint: XCTUnwrap(URL(string: "https://example.com/forged"))
        )
        let result = await client.search(forged)
        XCTAssertEqual(result, .failure(.input))
        let urls = await transport.urls
        XCTAssertTrue(urls.isEmpty)
    }

    private func payload(total: Any, incomplete: Any, items: [[String: String]]) throws -> BeholderPayload {
        try .init(
            data: JSONSerialization.data(withJSONObject: ["total_count": total, "incomplete_results": incomplete, "items": items]),
            status: 200
        )
    }

    @MainActor private func finish(while busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy(), "Invented request did not finish")
    }
}

private actor GitHubDiscoveryFixtureTransport: BeholderTransport {
    private(set) var urls: [URL] = []
    func get(_ url: URL, accept _: String) async throws -> BeholderPayload {
        urls.append(url)
        let body = url.path == "/search/users"
            ? #"{"total_count":1,"incomplete_results":false,"items":[{"login":"ExampleAlex","type":"User","url":"https://example.com/ignored"}]}"#
            : #"{"login":"ExampleAlex","type":"User","name":"Example Alex","email":"example@example.com"}"#
        return BeholderPayload(data: Data(body.utf8), status: 200)
    }
}

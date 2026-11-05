@testable import Aegis
import XCTest

@MainActor
final class BeholderUnifiedSearchTests: XCTestCase {
    func testRecognitionAndFinalValidation() {
        let search = BeholderModel().unifiedSearch
        for (text, expected) in [
            ("@ExampleAlex", BeholderCaseSearch.Kind.username),
            ("Example_Alex", .username), ("Example Alex", .name),
            ("example+tag@example.com", .email), ("mailto:example@example.com", .email),
            ("+61 400 000 001", .phone), ("0400 000 001", .phone),
            ("203.0.113.1", .ip), ("2001:db8::1", .ip),
        ] {
            search.query = text
            XCTAssertEqual(search.kind, expected, text)
            XCTAssertEqual(search.canPrepare, text != "0400 000 001", text)
        }
        for text in ["", "Example\nAlex", "Example\u{2028}Alex", "example@example.com?private=x", "203.0.113.999", "https://example.com"] {
            search.query = text
            search.prepare()
            XCTAssertFalse(search.canPrepare, text)
            XCTAssertNil(search.prepared)
        }
        search.query = "0400 000 001"
        search.region = .australia
        XCTAssertTrue(search.canPrepare)
        search.prepare()
        XCTAssertEqual(BeholderIdentifier(input: search.query, kind: .phone, region: search.region)?.value, "+61400000001")
        search.query = "https://github.com/ExampleAlex"
        XCTAssertNil(search.kind)
        XCTAssertTrue(search.inputHint?.contains("profile link") == true)
    }

    func testAmbiguityCanBeCorrectedWithoutRetyping() {
        let search = BeholderModel().unifiedSearch
        search.query = "Example"
        XCTAssertTrue(search.ambiguous)
        search.interpret(as: .name)
        XCTAssertEqual(search.query, "Example")
        XCTAssertEqual(search.kind, .name)
        search.prepare()
        XCTAssertEqual(search.prepared?.kind, .name)
        search.interpret(as: nil)
        XCTAssertNil(search.prepared)
        XCTAssertTrue(search.ambiguous)
        search.query = "example@example.com"
        search.interpret(as: .username)
        search.prepare()
        XCTAssertNil(search.prepared, "Overrides must still pass the original username validator.")
    }

    func testPreparingAndChoosingSourcesNeverRequestsData() async throws {
        let client = UnifiedSearchFixture()
        let model = BeholderModel(client: client, discoveryClient: client)
        let search = model.unifiedSearch
        search.query = "Example Unlisted"
        search.prepare()
        search.chooseGitHub()
        var counts = await client.counts
        XCTAssertEqual(counts, [0, 0, 0])
        XCTAssertEqual(model.githubDiscovery.prepared?.seed, "Example Unlisted")
        model.githubDiscovery.search()
        try await finish { model.githubDiscovery.searching }
        counts = await client.counts
        XCTAssertEqual(counts, [0, 1, 0])
        XCTAssertTrue(model.correlation.accounts.isEmpty)
        let exported = try XCTUnwrap(String(data: model.export(), encoding: .utf8))
        XCTAssertFalse(exported.contains("Example Unlisted"))
        try model.githubDiscovery.inspect(XCTUnwrap(model.githubDiscovery.page?.hits.first), into: model)
        try await finish { model.githubDiscovery.inspecting != nil }
        counts = await client.counts
        XCTAssertEqual(counts, [0, 1, 1])
        XCTAssertEqual(model.correlation.accounts.count, 1)

        search.query = "@ExampleAlex"
        search.prepare()
        XCTAssertEqual(search.report(in: model)?.total, 1)
        XCTAssertNil(model.githubDiscovery.page)
        model.selected = [.github]
        search.searchProfiles(in: model)
        try await finish { model.searching }
        counts = await client.counts
        XCTAssertEqual(counts, [1, 1, 1])
    }

    func testImportDiscardsIntentWhileCloseAndFailedImportKeepLocalSearch() throws {
        let model = BeholderModel()
        model.query = "ExampleRestored"
        XCTAssertEqual(model.unifiedSearch.query, "")
        let snapshot = try model.export()
        model.unifiedSearch.query = "Example Alex"
        model.unifiedSearch.prepare()
        model.unifiedSearch.chooseGitHub()
        XCTAssertThrowsError(try model.importCase(Data("{}".utf8)))
        XCTAssertNotNil(model.githubDiscovery.prepared)
        XCTAssertEqual(model.unifiedSearch.query, "Example Alex")
        try model.importCase(snapshot)
        XCTAssertEqual(model.unifiedSearch.query, "")
        XCTAssertNil(model.unifiedSearch.prepared)
        XCTAssertNil(model.githubDiscovery.prepared)
        model.unifiedSearch.query = "example@example.com"
        model.unifiedSearch.prepare()
        model.unifiedSearch.chooseGitHub()
        model.cancel()
        XCTAssertEqual(model.unifiedSearch.query, "example@example.com")
        XCTAssertNotNil(model.unifiedSearch.prepared)
        XCTAssertNil(model.githubDiscovery.prepared)
    }

    func testSavedEvidenceAndPreparedRoutesFollowTheDetectedKind() throws {
        let model = BeholderModel(), search = model.unifiedSearch
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        model.correlation.observe(username: "ExampleAlex", finding: .init(
            provider: .github, status: .candidate, checkedAt: date,
            sourceURL: BeholderProvider.github.endpoint("ExampleAlex"),
            fields: ["Display name": "Example Alex", "Public email": "example@example.com"]
        ))
        try model.correlation.record(
            accountID: "github:examplealex",
            identifier: XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone)),
            source: "https://example.com/contact", now: date
        )
        for value in ["Example Alex", "example@example.com", "+61 400 000 001"] {
            search.query = value; search.prepare()
            XCTAssertEqual(search.report(in: model)?.total, 1)
            let input = try XCTUnwrap(search.prepared)
            let browser = try XCTUnwrap(BeholderPublicSearch.prepare(input, service: .duckDuckGo))
            XCTAssertEqual(browser.host, "duckduckgo.com")
            search.chooseGitHub()
            if input.kind == .phone {
                XCTAssertEqual(browser.query, "\"+61400000001\"")
                XCTAssertNil(model.githubDiscovery.prepared)
                XCTAssertNil(BeholderPublicSearch.prepare(input, service: .github))
            } else {
                XCTAssertEqual(model.githubDiscovery.prepared?.input.kind, input.kind == .name ? .name : .email)
            }
        }
        search.query = "203.0.113.1"; search.prepare(); search.chooseGitHub()
        XCTAssertNotNil(search.ip); XCTAssertNil(search.report(in: model))
        XCTAssertNil(model.githubDiscovery.prepared)
        let input = try XCTUnwrap(search.prepared)
        for service in BeholderPublicSearch.Service.allCases {
            XCTAssertNil(BeholderPublicSearch.prepare(input, service: service))
        }
        model.clear()
        XCTAssertNil(search.prepared)
        XCTAssertEqual(search.query, "")
    }

    private func finish(while busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy())
    }
}

private actor UnifiedSearchFixture: BeholderSearching, BeholderGitHubDiscovering {
    private(set) var counts = [0, 0, 0]
    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        counts[0] += 1
        return finding(provider: provider, username: username)
    }

    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        counts[1] += 1
        return .success(.init(request: request, hits: [.init(login: "ExampleAlex")], total: 1, incomplete: false, checkedAt: Date()))
    }

    func inspect(_ login: String) async -> BeholderFinding {
        counts[2] += 1
        return finding(provider: .github, username: login)
    }

    private func finding(provider: BeholderProvider, username: String) -> BeholderFinding {
        .init(
            provider: provider,
            status: .candidate,
            checkedAt: Date(),
            sourceURL: provider.endpoint(username),
            fields: ["Handle": username, "Account type": "User", "Display name": "Example Alex"]
        )
    }
}

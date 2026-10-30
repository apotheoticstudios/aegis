@testable import Aegis
import Foundation
import XCTest

final class BeholderCoverageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let fixtures: [BeholderProvider: String] = [
        .codeberg: #"{"login":"examplealex","full_name":"Example Alex","description":"Example bio"}"#,
        .dockerHub: #"{"username":"examplealex","full_name":"Example Alex"}"#,
        .keybase: #"{"status":{"code":0},"them":[{"basics":{"username":"examplealex"},"profile":{"full_name":"Example Alex"}}]}"#,
        .lichess: #"{"id":"examplealex","username":"ExampleAlex"}"#,
        .chess: #"{"username":"examplealex","name":"Example Alex","status":"premium"}"#,
        .scratch: #"{"username":"ExampleAlex","profile":{"bio":"Example bio"}}"#,
        .bluesky: #"{"handle":"examplealex.bsky.social","did":"did:plc:example","displayName":"Example Alex"}"#,
        .mastodon: #"{"username":"ExampleAlex","acct":"examplealex","display_name":"Example Alex","note":"<p>Example bio</p>"}"#,
    ]

    func testExpandedProfilesRequireExactIdentifiers() throws {
        XCTAssertEqual(BeholderProvider.allCases.count, 12)
        for provider in fixtures.keys {
            let json = try XCTUnwrap(fixtures[provider])
            let result = parse(json, provider)
            XCTAssertEqual(result.status, .candidate)
            XCTAssertEqual(result.sourceURL, provider.endpoint("ExampleAlex"))
            XCTAssertEqual(result.checkedAt, now)
            XCTAssertEqual(result.fields["Handle"]?.lowercased(), provider.lookupHandle("ExampleAlex"))
            XCTAssertEqual(parse(
                json.replacingOccurrences(of: "examplealex", with: "exampleother")
                    .replacingOccurrences(of: "ExampleAlex", with: "ExampleOther"),
                provider
            ).status, .unavailable)
            XCTAssertEqual(parse(#"{"name":"ExampleAlex","status":"ok"}"#, provider).status, .unavailable)
            XCTAssertEqual(parse("<html>Sign in</html>", provider).status, .unavailable)
        }
    }

    func testProviderSpecificMissingAndRemoteAccounts() {
        XCTAssertEqual(parse(#"{"status":{"code":0},"them":[null]}"#, .keybase).status, .noResult)
        XCTAssertEqual(parse(#"{"status":{"code":0},"them":[]}"#, .keybase).status, .noResult)
        XCTAssertEqual(parse(#"{"status":{"code":1},"them":[null]}"#, .keybase).status, .unavailable)
        XCTAssertEqual(parse(#"{"username":"ExampleAlex","acct":"examplealex@elsewhere.example.com"}"#, .mastodon).status, .unavailable)
        XCTAssertEqual(parse(#"{"handle":"examplealex.example.com"}"#, .bluesky).status, .unavailable)
        for provider in fixtures.keys {
            XCTAssertEqual(parse("{}", provider, status: 401).status, .unavailable)
            XCTAssertEqual(parse("{}", provider, status: 403).status, .unavailable)
            XCTAssertEqual(parse("{}", provider, status: 429).status, .limited)
            XCTAssertEqual(parse("{}", provider, status: 404).status, .noResult)
        }
    }

    func testClosedDestinationsAndProviderSyntax() throws {
        for provider in BeholderProvider.allCases {
            let url = try XCTUnwrap(provider.endpoint("ExampleAlex"))
            XCTAssertTrue(BeholderProvider.permits(url))
            var altered = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            altered.queryItems = (altered.queryItems ?? []) + [URLQueryItem(name: "extra", value: "private")]
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(altered.url)))
            altered = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            altered.user = "Example"
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(altered.url)))
            altered.user = nil
            altered.port = 8443
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(altered.url)))
            altered.port = nil
            altered.fragment = "Example"
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(altered.url)))
        }
        XCTAssertNil(BeholderProvider.dockerHub.endpoint("Example_Alex"))
        XCTAssertNil(BeholderProvider.mastodon.endpoint("ExampleAlex.example.com"))
        XCTAssertNil(BeholderProvider.bluesky.endpoint("ExampleAlex.example.com"))
        let longBluesky = try XCTUnwrap(BeholderProvider.bluesky.endpoint(String(repeating: "a", count: 63)))
        XCTAssertTrue(BeholderProvider.permits(longBluesky))
        XCTAssertEqual(BeholderProvider.bluesky.endpoint("ExampleAlex"), BeholderProvider.bluesky.endpoint("examplealex.bsky.social"))
    }

    @MainActor func testDefaultScopeAndBoundedCancellation() async throws {
        let service = CoverageSearch()
        let model = BeholderModel(client: service)
        XCTAssertEqual(model.selected, BeholderProvider.originalSources)
        model.selected = Set(BeholderProvider.allCases)
        model.query = "ExampleAlex"
        model.start()
        try await service.waitFor(4)
        XCTAssertEqual(model.findings.filter { $0.status == .queued }.count, 8)
        await service.release(.github)
        try await service.waitFor(5)
        let peak = await service.peak
        XCTAssertEqual(peak, 4)
        model.cancel()
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.findings.allSatisfy { [.candidate, .cancelled].contains($0.status) })
        await service.releaseAll()
        try await Task.sleep(for: .milliseconds(20))
        let total = await service.started
        XCTAssertEqual(total, 5, "Stop must not start queued lookups")
        XCTAssertEqual(model.candidates, 1)
    }

    @MainActor func testCompletionKeepsCatalogueOrderAcrossBatches() async throws {
        let service = CoverageSearch()
        let model = BeholderModel(client: service)
        model.selected = Set(BeholderProvider.allCases)
        model.query = "ExampleAlex"
        model.start()
        for count in [4, 8, 12] {
            try await service.waitFor(count)
            await service.releaseAll()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.searching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.findings.map(\.provider), BeholderProvider.allCases)
        XCTAssertTrue(model.findings.allSatisfy { $0.status == .candidate })
        let peak = await service.peak
        XCTAssertEqual(peak, 4)
    }

    @MainActor func testImmediateStopStartsNoLookup() async throws {
        let service = CoverageSearch()
        let model = BeholderModel(client: service)
        model.selected = Set(BeholderProvider.allCases)
        model.query = "ExampleAlex"
        model.start()
        model.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let count = await service.started
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.findings.allSatisfy { $0.status == .cancelled })
    }

    private func parse(_ json: String, _ provider: BeholderProvider, status: Int = 200) -> BeholderFinding {
        BeholderClient.parse(BeholderPayload(data: Data(json.utf8), status: status), provider: provider, username: "ExampleAlex", now: now)
    }
}

private actor CoverageSearch: BeholderSearching {
    var started = 0
    var peak = 0
    private var pending: [BeholderProvider: CheckedContinuation<BeholderFinding, Never>] = [:]
    func lookup(_ provider: BeholderProvider, username _: String) async -> BeholderFinding {
        started += 1
        return await withCheckedContinuation { continuation in
            pending[provider] = continuation
            peak = max(peak, pending.count)
        }
    }

    func waitFor(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while started < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        if started < count {
            throw URLError(.timedOut)
        }
    }

    func release(_ provider: BeholderProvider) {
        pending.removeValue(forKey: provider)?.resume(returning: BeholderFinding(provider: provider, status: .candidate))
    }

    func releaseAll() {
        for provider in BeholderProvider.allCases.reversed() {
            release(provider)
        }
    }
}

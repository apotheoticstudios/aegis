@testable import Aegis
import XCTest

@MainActor
final class BeholderUnifiedLifecycleTests: XCTestCase {
    func testEditsDiscardLateGitHubSearchesAndInspections() async throws {
        for boundary in 0 ..< 4 {
            let client = UnifiedPendingClient()
            let model = BeholderModel(discoveryClient: client)
            let search = model.unifiedSearch, github = model.githubDiscovery
            search.query = "Example Alex"; search.prepare(); search.chooseGitHub(); github.search()
            try await started { await client.waiting }
            await client.finish()
            try await finished { github.searching }
            try github.inspect(XCTUnwrap(github.page?.hits.first), into: model)
            try await started { await client.waiting }
            switch boundary {
            case 0: search.query = "Example Jamie"
            case 1: search.interpret(as: .username)
            case 2: search.region = .australia
            default: try model.importCase(BeholderModel().export())
            }
            XCTAssertNil(search.prepared); XCTAssertNil(github.prepared)
            XCTAssertNil(github.inspecting)
            await client.finish()
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertNil(github.inspected)
            XCTAssertTrue(model.correlation.accounts.isEmpty)

            search.query = "Example Unlisted"; search.prepare(); search.chooseGitHub(); github.search()
            try await started { await client.waiting }
            search.query = "Example New"
            await client.finish()
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertNil(github.page); XCTAssertNil(github.prepared)
        }
    }

    func testEditingUsernameCancelsCheckBeforeLateResultCanBeSaved() async throws {
        let client = UnifiedPendingClient()
        let research = BeholderModel(client: client)
        research.selected = [.github]
        research.unifiedSearch.query = "@ExampleAlex"
        research.unifiedSearch.prepare(); research.unifiedSearch.searchProfiles(in: research)
        try await started { await client.waiting }
        research.unifiedSearch.query = "example@example.com"
        XCTAssertFalse(research.searching)
        XCTAssertNil(research.unifiedSearch.profileQuery)
        let before = research.correlation
        await client.finish()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(research.correlation, before)
        XCTAssertFalse(research.findings.contains { $0.status == .candidate })
    }

    func testCloseKeepsLocalSearchButDiscardsLatePublicResults() async throws {
        let client = UnifiedPendingClient()
        let model = BeholderModel(client: client, discoveryClient: client)
        let search = model.unifiedSearch
        search.query = "Example Alex"; search.prepare(); search.chooseGitHub(); model.githubDiscovery.search()
        try await started { await client.waiting }
        let input = search.prepared
        model.cancel()
        XCTAssertEqual(search.prepared, input); XCTAssertEqual(search.query, "Example Alex")
        XCTAssertNil(model.githubDiscovery.prepared)
        await client.finish()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNil(model.githubDiscovery.page)
        model.selected = [.github]
        search.query = "@ExampleAlex"; search.prepare(); search.searchProfiles(in: model)
        try await started { await client.waiting }
        model.cancel()
        let before = model.correlation
        XCTAssertEqual(search.query, "@ExampleAlex"); XCTAssertNotNil(search.prepared)
        XCTAssertNil(search.profileQuery); XCTAssertFalse(model.searching)
        await client.finish()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.correlation, before)
        model.clear()
        XCTAssertEqual(search.query, ""); XCTAssertNil(search.prepared)
    }

    private func started(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let actual = await ready(); XCTAssertTrue(actual)
    }

    private func finished(_ busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy())
    }
}

private actor UnifiedPendingClient: BeholderSearching, BeholderGitHubDiscovering {
    private var complete: (() -> Void)?
    var waiting: Bool {
        complete != nil
    }

    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        await withCheckedContinuation { continuation in
            complete = { continuation.resume(returning: Self.finding(provider, username)) }
        }
    }

    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        await withCheckedContinuation { continuation in
            complete = { continuation.resume(returning: .success(.init(
                request: request, hits: [.init(login: "ExampleAlex")], total: 1,
                incomplete: false, checkedAt: Date(timeIntervalSince1970: 1_790_000_000)
            ))) }
        }
    }

    func inspect(_ login: String) async -> BeholderFinding {
        await lookup(.github, username: login)
    }

    func finish() {
        let callback = complete; complete = nil; callback?()
    }

    private static func finding(_ provider: BeholderProvider, _ username: String) -> BeholderFinding {
        .init(
            provider: provider,
            status: .candidate,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000),
            sourceURL: provider.endpoint(username),
            fields: ["Handle": username, "Account type": "User"]
        )
    }
}

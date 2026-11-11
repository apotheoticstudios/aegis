@testable import Aegis
import XCTest

@MainActor
final class BeholderAutomaticSearchTests: XCTestCase {
    func testSearchRunsAllAutomaticUsernameSourcesWithoutManualLinks() async throws {
        let client = AutomaticSearchFixture()
        let model = BeholderModel(client: client, discoveryClient: client)
        let search = model.unifiedSearch
        search.query = "@Example"
        search.interpret(as: .username)
        let before = await client.calls
        XCTAssertEqual(before, [0, 0, 0])
        model.selected = [.instagram]
        search.run(in: model)
        try await finish { model.searching }
        let sources = await client.sources
        XCTAssertEqual(Set(sources), Set(BeholderProvider.automaticSources))
        XCTAssertFalse(model.findings.contains { $0.status == .manual })
        XCTAssertEqual(search.profileQuery, "Example")
    }

    func testNameAndEmailSearchRetrieveProfilesAutomaticallyWithBoundedConcurrency() async throws {
        let client = AutomaticSearchFixture()
        let model = BeholderModel(client: client, discoveryClient: client)
        model.unifiedSearch.query = "Example Seed"
        model.unifiedSearch.run(in: model)
        try await finish { model.githubDiscovery.searching }
        let calls = await client.calls, maximum = await client.maximum
        XCTAssertEqual(calls, [0, 1, 20])
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertEqual(model.githubDiscovery.profiles.count, 20)
        XCTAssertEqual(model.correlation.accounts.count, 20)
        XCTAssertTrue(model.people.people.isEmpty)
        let exported = try XCTUnwrap(String(data: model.export(), encoding: .utf8))
        XCTAssertFalse(exported.contains("Example Seed"))
        model.unifiedSearch.query = "example@example.com"
        model.unifiedSearch.run(in: model)
        try await finish { model.githubDiscovery.searching }
        let afterEmail = await client.calls
        XCTAssertEqual(afterEmail, [0, 2, 40])
        model.unifiedSearch.query = "+61 400 000 001"; model.unifiedSearch.run(in: model)
        model.unifiedSearch.query = "203.0.113.1"; model.unifiedSearch.run(in: model)
        let afterLocal = await client.calls
        XCTAssertEqual(afterLocal, afterEmail)
    }

    func testOversizedPageCannotStartProfileRequests() async throws {
        let client = AutomaticSearchFixture(count: 21)
        let model = BeholderModel(discoveryClient: client)
        model.unifiedSearch.query = "Example Seed"; model.unifiedSearch.run(in: model)
        try await finish { model.githubDiscovery.searching }
        let calls = await client.calls
        XCTAssertEqual(calls, [0, 1, 0])
        XCTAssertEqual(model.githubDiscovery.problem, .response)
        XCTAssertNil(model.githubDiscovery.page)
        XCTAssertTrue(model.correlation.accounts.isEmpty)
    }

    func testRateLimitStopsSchedulingMoreProfiles() async throws {
        let client = AutomaticSearchFixture(limited: true)
        let model = BeholderModel(discoveryClient: client)
        model.unifiedSearch.query = "Example Seed"; model.unifiedSearch.run(in: model)
        try await finish { model.githubDiscovery.searching }
        let calls = await client.calls
        XCTAssertLessThanOrEqual(calls[2], 4)
        XCTAssertEqual(model.githubDiscovery.problem, .limited)
        XCTAssertEqual(model.githubDiscovery.checkedCount, 1)
        XCTAssertEqual(model.githubDiscovery.unresolvedCount, 1)
        XCTAssertEqual(model.githubDiscovery.pendingHits.count, 19)
    }

    func testFoundProfilesKeepSearchOrderAndInvalidProfilesCountAsFailedChecks() async throws {
        let model = BeholderModel(discoveryClient: MixedAutomaticProfiles())
        model.unifiedSearch.query = "Example Seed"; model.unifiedSearch.run(in: model)
        try await finish { model.githubDiscovery.searching }
        XCTAssertEqual(model.githubDiscovery.foundHits.map(\.login), ["ExampleFoundFirst", "ExampleFoundSecond"])
        XCTAssertEqual(model.githubDiscovery.otherHits.map(\.login), ["ExampleUnavailable", "ExampleMissing", "ExampleInvalid"])
        XCTAssertEqual(model.githubDiscovery.checkedCount, 5)
        XCTAssertEqual(model.githubDiscovery.unresolvedCount, 2)
        XCTAssertTrue(model.githubDiscovery.pendingHits.isEmpty)
        XCTAssertEqual(model.githubDiscovery.rejectedProfiles, ["ExampleInvalid"])
        XCTAssertEqual(model.correlation.accounts.count, 2)
        XCTAssertTrue(model.people.people.isEmpty)
    }

    func testStopKeepsCompletedProfilesAndShowsUnfinishedCoverage() async throws {
        let client = PendingAutomaticProfile(includeCompleted: true), model = BeholderModel(discoveryClient: client)
        model.unifiedSearch.query = "Example Seed"; model.unifiedSearch.run(in: model)
        try await started(client)
        try await finish { model.githubDiscovery.checkedCount == 0 }
        model.githubDiscovery.stop()
        await client.complete()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(model.githubDiscovery.searching)
        XCTAssertEqual(model.githubDiscovery.foundHits.map(\.login), ["ExampleDone"])
        XCTAssertEqual(model.githubDiscovery.pendingHits.map(\.login), ["ExampleLate"])
        XCTAssertEqual(model.githubDiscovery.checkedCount, 1)
        XCTAssertEqual(model.correlation.accounts.count, 1)
        model.clear()
        XCTAssertTrue(model.githubDiscovery.profiles.isEmpty)
        XCTAssertTrue(model.githubDiscovery.pendingHits.isEmpty)
    }

    func testSessionBoundariesExcludeLateAutomaticProfiles() async throws {
        for boundary in 0 ..< 6 {
            let client = PendingAutomaticProfile()
            let model = BeholderModel(discoveryClient: client)
            model.unifiedSearch.query = "Example Seed"; model.unifiedSearch.run(in: model)
            try await started(client)
            switch boundary {
            case 0: model.unifiedSearch.query = "Example Changed"
            case 1: model.cancel()
            case 2: try model.importCase(BeholderModel().export())
            case 3: model.githubDiscovery.stop()
            case 4: model.clear()
            default:
                model.unifiedSearch.run(in: model)
                try await finish { model.githubDiscovery.searching }
            }
            await client.complete()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(model.correlation.accounts.isEmpty)
            XCTAssertTrue(model.githubDiscovery.profiles.isEmpty)
            XCTAssertFalse(model.githubDiscovery.searching)
        }
    }

    private func started(_ client: PendingAutomaticProfile) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !(client.started), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let ready = await client.started
        XCTAssertTrue(ready)
    }

    private func finish(_ busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy())
    }
}

private actor AutomaticSearchFixture: BeholderSearching, BeholderGitHubDiscovering {
    private let count: Int
    private let limited: Bool
    private(set) var calls = [0, 0, 0]
    private(set) var sources: [BeholderProvider] = []
    private(set) var maximum = 0
    private var active = 0

    init(count: Int = 20, limited: Bool = false) {
        self.count = count; self.limited = limited
    }

    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        calls[0] += 1; sources.append(provider)
        return .init(provider: provider, status: .unavailable, sourceURL: provider.endpoint(username))
    }

    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        calls[1] += 1
        return .success(.init(
            request: request, hits: (0 ..< count).map { .init(login: "ExampleProfile\($0)") },
            total: count, incomplete: false, checkedAt: Date(timeIntervalSince1970: 1_790_000_000)
        ))
    }

    func inspect(_ login: String) async -> BeholderFinding {
        calls[2] += 1; active += 1; maximum = max(maximum, active)
        try? await Task.sleep(for: .milliseconds(10))
        active -= 1
        return automaticFinding(login, limited: limited)
    }
}

private actor PendingAutomaticProfile: BeholderGitHubDiscovering {
    private var completion: CheckedContinuation<BeholderFinding, Never>?
    private var searches = 0
    private let includeCompleted: Bool

    init(includeCompleted: Bool = false) {
        self.includeCompleted = includeCompleted
    }

    var started: Bool {
        completion != nil
    }

    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        searches += 1
        let logins = searches > 1 ? [] : (includeCompleted ? ["ExampleDone", "ExampleLate"] : ["ExampleLate"])
        return .success(.init(
            request: request,
            hits: logins.map { .init(login: $0) },
            total: logins.count,
            incomplete: false,
            checkedAt: Date()
        ))
    }

    func inspect(_ login: String) async -> BeholderFinding {
        if login == "ExampleDone" {
            return automaticFinding(login)
        }
        return await withCheckedContinuation { completion = $0 }
    }

    func complete() {
        completion?.resume(returning: automaticFinding("ExampleLate")); completion = nil
    }
}

private struct MixedAutomaticProfiles: BeholderGitHubDiscovering {
    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        let logins = ["ExampleUnavailable", "ExampleFoundFirst", "ExampleMissing", "ExampleInvalid", "ExampleFoundSecond"]
        return .success(.init(request: request, hits: logins.map { .init(login: $0) }, total: 5, incomplete: false, checkedAt: Date()))
    }

    func inspect(_ login: String) async -> BeholderFinding {
        var result = automaticFinding(login)
        if login == "ExampleInvalid" {
            result.sourceURL = URL(string: "https://example.com/invalid")
        } else if login == "ExampleUnavailable" || login == "ExampleMissing" {
            result.status = login == "ExampleMissing" ? .noResult : .unavailable; result.fields = [:]
        }
        return result
    }
}

private func automaticFinding(_ login: String, limited: Bool = false) -> BeholderFinding {
    .init(
        provider: .github, status: limited ? .limited : .candidate,
        checkedAt: Date(timeIntervalSince1970: 1_790_000_000), sourceURL: BeholderProvider.github.endpoint(login),
        fields: limited ? [:] : ["Handle": login, "Account type": "User", "Display name": "Example Public Profile"]
    )
}

@testable import Aegis
import XCTest

final class BeholderGitHubLifecycleTests: XCTestCase {
    @MainActor func testInputAndKindChangesDiscardLateSearchCompletions() async throws {
        let client = PendingGitHubClient(), research = BeholderGitHubResearch(client: PendingGitHubClient())
        research.value = "Example Alex"; research.chooseGitHub()
        XCTAssertNotNil(research.prepared)
        research.kind = .email
        XCTAssertEqual(research.value, ""); XCTAssertNil(research.prepared)
        let pending = BeholderGitHubResearch(client: client)
        pending.value = "Example Alex"; pending.chooseGitHub(); pending.search()
        try await waitFor({ await client.searchCount }, expected: 1)
        pending.value = "Example Jamie"
        XCTAssertFalse(pending.searching); XCTAssertNil(pending.prepared)
        await client.finishSearch()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNil(pending.page)
        XCTAssertEqual(pending.value, "Example Jamie")
    }

    @MainActor func testCaseReplacementAndResetCannotArchiveLateInspection() async throws {
        let client = PendingGitHubClient(), research = BeholderGitHubResearch(client: client), model = BeholderModel()
        research.value = "Example Alex"; research.chooseGitHub(); research.search()
        try await waitFor({ await client.searchCount }, expected: 1)
        await client.finishSearch()
        try await waitUntil { research.searching }
        let hit = try XCTUnwrap(research.page?.hits.first)
        research.inspect(hit, into: model)
        try await waitFor({ await client.inspectionCount }, expected: 1)
        model.clear()
        await client.finishInspection()
        try await waitUntil { research.inspecting != nil }
        XCTAssertTrue(model.correlation.accounts.isEmpty)
        XCTAssertNil(research.inspected); XCTAssertEqual(research.problem, .context)
        research.inspect(hit, into: model)
        try await waitFor({ await client.inspectionCount }, expected: 2)
        research.reset()
        await client.finishInspection()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.correlation.accounts.isEmpty)
        XCTAssertNil(research.page); XCTAssertNil(research.inspected); XCTAssertEqual(research.value, "")
    }

    @MainActor func testInspectedProfileValidationDoesNotPoisonCaseExport() throws {
        let model = BeholderModel(), login = "ExampleAlex"
        var finding = BeholderFinding(
            provider: .github,
            status: .candidate,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000),
            sourceURL: BeholderProvider.github.endpoint(login),
            fields: ["Handle": login, "Account type": "User"]
        )
        XCTAssertTrue(model.recordGitHubInspection(login: login, finding: finding))
        let before = model.correlation
        finding.fields["Unexpected"] = "Example untrusted field"
        XCTAssertFalse(model.recordGitHubInspection(login: login, finding: finding))
        XCTAssertEqual(model.correlation, before)
        XCTAssertNoThrow(try model.export())
        finding.fields.removeValue(forKey: "Unexpected"); finding.fields["Handle"] = "ExampleOther"
        XCTAssertFalse(model.recordGitHubInspection(login: login, finding: finding))
        XCTAssertEqual(model.correlation, before)
    }

    @MainActor func testModelCancelAndImportResetDiscoverySynchronously() async throws {
        let client = PendingGitHubClient(), model = BeholderModel(discoveryClient: client)
        model.query = "ExampleExisting"
        let research = model.githubDiscovery
        XCTAssertEqual(research.value, "", "An existing case query is never a discovery seed")
        research.value = "Example Alex"; research.chooseGitHub(); research.search()
        try await waitFor({ await client.searchCount }, expected: 1)
        model.cancel()
        XCTAssertNil(research.prepared); XCTAssertFalse(research.searching); XCTAssertEqual(research.value, "")
        await client.finishSearch()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNil(research.page)
        research.value = "Example Jamie"; research.chooseGitHub()
        XCTAssertThrowsError(try model.importCase(Data("{}".utf8)))
        XCTAssertNotNil(research.prepared, "A rejected import keeps the current owner-prepared request")
        try model.importCase(BeholderModel().export())
        XCTAssertNil(research.prepared); XCTAssertEqual(research.value, "")
        let requests = await client.searchCount
        XCTAssertEqual(requests, 1)
    }

    @MainActor private func waitFor(_ count: @Sendable () async -> Int, expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await count() < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let actual = await count(); XCTAssertEqual(actual, expected)
    }

    @MainActor private func waitUntil(_ busy: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while busy(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(busy())
    }
}

private actor PendingGitHubClient: BeholderGitHubDiscovering {
    private(set) var searchCount = 0
    private(set) var inspectionCount = 0
    private var searchRequest: BeholderGitHubDiscovery.Request?
    private var searchCompletion: CheckedContinuation<Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem>, Never>?
    private var inspectionLogin = ""
    private var inspectionCompletion: CheckedContinuation<BeholderFinding, Never>?

    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        searchCount += 1; searchRequest = request
        return await withCheckedContinuation { searchCompletion = $0 }
    }

    func inspect(_ login: String) async -> BeholderFinding {
        inspectionCount += 1; inspectionLogin = login
        return await withCheckedContinuation { inspectionCompletion = $0 }
    }

    func finishSearch() {
        guard let request = searchRequest else { return }
        searchCompletion?.resume(returning: .success(.init(
            request: request,
            hits: [.init(login: "ExampleAlex")],
            total: 1,
            incomplete: false,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )))
        searchCompletion = nil; searchRequest = nil
    }

    func finishInspection() {
        inspectionCompletion?.resume(returning: .init(
            provider: .github,
            status: .candidate,
            checkedAt: Date(timeIntervalSince1970: 1_790_000_000),
            sourceURL: BeholderProvider.github.endpoint(inspectionLogin),
            fields: ["Handle": inspectionLogin, "Account type": "User"]
        ))
        inspectionCompletion = nil
    }
}

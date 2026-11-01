@testable import Aegis
import XCTest

final class BeholderCaseIntegrationTests: XCTestCase {
    @MainActor func testCaseImportRestoresEvidenceWithoutRequestsAndMarksFileClaims() async throws {
        let client = CaseCountingClient()
        let original = BeholderModel(client: client)
        original.selected = [.github]
        for name in ["ExampleAlex", "ExampleOther"] {
            original.query = name; original.start()
            try await finished(original)
        }
        let person = try original.people.create("Example Alex")
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        try original.correlation.identify(
            personID: person,
            identifier: identifier,
            source: "https://example.com/author",
            now: .init(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try original.export()
        let restored = BeholderModel(client: client)
        restored.selected = [.instagram]
        try restored.importCase(data)
        XCTAssertTrue(restored.includesImportedObservations)
        XCTAssertFalse(restored.searching)
        XCTAssertEqual(restored.username, original.username)
        XCTAssertEqual(restored.people, original.people)
        XCTAssertEqual(restored.correlation.accounts, original.correlation.accounts)
        XCTAssertEqual(restored.correlation.leads(for: restored.people.people[0]).count, 2)
        XCTAssertEqual(restored.selected, [.instagram], "File data cannot select outgoing lookup destinations")
        let requests = await client.requests
        XCTAssertEqual(requests, 2)
        let again = try BeholderCaseFile.decode(restored.export())
        XCTAssertEqual(again.people, restored.people)
        // ISO timestamps have whole-second precision in the exported document.
        XCTAssertEqual(again.importedFrom?.sourceExportedAt, restored.importProvenance?.sourceExportedAt)
        XCTAssertEqual(
            again.importedFrom?.importedAt.timeIntervalSince1970,
            restored.importProvenance?.importedAt.timeIntervalSince1970.rounded(.down)
        )
        XCTAssertNotNil(restored.importDescription)
        XCTAssertTrue(again.provenanceNote.contains("phone/email"))
        restored.clear()
        XCTAssertFalse(restored.includesImportedObservations)
        XCTAssertFalse(restored.hasCase)
    }

    @MainActor func testMalformedImportLeavesActiveSearchAndCaseUntouched() throws {
        let model = BeholderModel(client: CaseCountingClient(delay: true))
        _ = try model.people.create("Example Person")
        model.query = "ExampleAlex"; model.selected = [.github]; model.start()
        XCTAssertTrue(model.searching)
        let people = model.people
        let findings = model.findings
        XCTAssertThrowsError(try model.importCase(Data("not a case".utf8)))
        XCTAssertEqual(model.people, people)
        XCTAssertEqual(model.findings, findings)
        XCTAssertEqual(model.username, "ExampleAlex")
        XCTAssertTrue(model.searching, "Validation failure must not cancel an existing lookup")
        XCTAssertFalse(model.includesImportedObservations)
        model.cancel()
    }

    @MainActor func testPeopleOnlyCaseAndImportedFlagSurvivesLaterSearch() async throws {
        let source = BeholderModel(client: CaseCountingClient())
        _ = try source.people.create("Example Person")
        let target = BeholderModel(client: CaseCountingClient())
        try target.importCase(source.export())
        XCTAssertEqual(target.username, "")
        XCTAssertTrue(target.includesImportedObservations)
        XCTAssertEqual(target.people.people, source.people.people)
        target.query = "ExampleAlex"; target.selected = [.github]; target.start()
        try await finished(target)
        XCTAssertTrue(target.includesImportedObservations, "Earlier case records still came from a file")
    }

    func testEvidenceURLsUseStrictComparisonValidationButKeepOriginalAnchors() {
        XCTAssertEqual(
            BeholderPeople.evidenceURL("https://example.com/author#contact")?.absoluteString,
            "https://example.com/author#contact"
        )
        for address in [
            "https://example.com/a%0Ab",
            "https://example.com/a%zz",
            "https://example.com/a/../other",
            "https://example.com/author#%0A",
            "https://example.com/author#%E2%80%AE",
        ] {
            XCTAssertNil(BeholderPeople.evidenceURL(address))
        }
    }

    @MainActor func testAllSourceCasesRemainExportableAfterStopAndRateLimit() async throws {
        let client = FullCaseClient()
        let model = BeholderModel(client: client)
        model.selected = Set(BeholderProvider.allCases)
        model.query = "ExampleAlex"; model.start()
        try await finished(model)
        XCTAssertEqual(model.findings.count, 72)
        for source in [BeholderProvider.github, .bluesky, .mastodon] {
            XCTAssertEqual(model.findings.first { $0.provider == source }?.status, .candidate)
        }
        let person = try model.people.create("Example Alex")
        let github = try XCTUnwrap(model.findings.first { $0.provider == .github })
        try model.people.link(
            personID: person,
            username: model.username,
            finding: github,
            assessment: .supported,
            reason: "Example author page links to this account",
            evidence: "https://example.com/author#accounts",
            now: .init(timeIntervalSince1970: 1_800_000_030)
        )
        try model.correlation.identify(
            personID: person,
            identifier: XCTUnwrap(BeholderIdentifier(input: "0400 000 001", kind: .phone, region: .australia)),
            source: "https://example.com/contact"
        )
        let original = try BeholderCaseFile.decode(model.export())
        XCTAssertEqual(original.findings.count, 72)
        XCTAssertEqual(original.people.people[0].links[0].assessment, .supported)
        XCTAssertTrue(original.correlation.evidence.contains { $0.origin == .publicField })
        await client.setSlow(true)
        model.start()
        model.cancel()
        let stopped = try BeholderCaseFile.decode(model.export())
        XCTAssertTrue(stopped.findings.filter { !$0.provider.isManual }.allSatisfy { $0.status == .cancelled })
        XCTAssertEqual(stopped.correlation.evidence, original.correlation.evidence)
        await client.setLimited()
        model.start(); try await finished(model)
        let limited = try BeholderCaseFile.decode(model.export())
        XCTAssertTrue(limited.findings.filter { !$0.provider.isManual }.allSatisfy { $0.status == .limited })
        XCTAssertEqual(limited.correlation.evidence, original.correlation.evidence)
        model.query = "Ex"; model.selected = [.youtube]; model.start()
        XCTAssertEqual(model.findings[0].status, .unsupported)
        let unsupported = try BeholderCaseFile.decode(model.export())
        XCTAssertEqual(unsupported.findings[0].status, .unsupported)
        let reopened = BeholderModel(client: client)
        try reopened.importCase(model.export())
        let firstSource = try XCTUnwrap(reopened.importProvenance?.sourceExportedAt)
        let twice = BeholderModel(client: client)
        try twice.importCase(reopened.export())
        XCTAssertEqual(twice.importProvenance?.sourceExportedAt, firstSource)
    }

    func testSelectedFileReaderEnforcesByteCapBeforeParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Beholder-Example-" + UUID().uuidString + ".json")
        let data = Data("Example synthetic case input".utf8)
        try data.write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try BeholderCaseInput.read(url), data)
        try Data(repeating: 32, count: BeholderCaseFile.byteLimit + 1).write(to: url)
        XCTAssertThrowsError(try BeholderCaseInput.read(url))
    }

    @MainActor private func finished(_ model: BeholderModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.searching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.searching)
    }
}

private actor FullCaseClient: BeholderSearching {
    private var slow = false
    private var limited = false
    func setSlow(_ value: Bool) {
        slow = value
    }

    func setLimited() {
        slow = false; limited = true
    }

    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        if slow {
            try? await Task.sleep(for: .seconds(1))
        }
        let status: BeholderFinding.Status = Task.isCancelled ? .cancelled : limited ? .limited
            : [.github, .bluesky, .mastodon].contains(provider) ? .candidate : .unavailable
        var fields: [String: String] = [:]
        if status == .candidate {
            fields["Handle"] = provider.lookupHandle(username)
            if provider == .github {
                fields["Public email"] = "example@example.com"
            }
        }
        return BeholderFinding(
            provider: provider,
            status: status,
            checkedAt: .init(timeIntervalSince1970: 1_800_000_000),
            sourceURL: provider.endpoint(username),
            fields: fields
        )
    }
}

private actor CaseCountingClient: BeholderSearching {
    let delay: Bool
    private(set) var requests = 0
    init(delay: Bool = false) {
        self.delay = delay
    }

    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        requests += 1
        if delay {
            try? await Task.sleep(for: .seconds(1))
        }
        return BeholderFinding(
            provider: provider,
            status: .candidate,
            checkedAt: .init(timeIntervalSince1970: 1_800_000_000),
            sourceURL: provider.endpoint(username),
            fields: ["Handle": username, "Public email": "example@example.com"]
        )
    }
}

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
        for address in ["https://example.com/a%0Ab", "https://example.com/a%zz", "https://example.com/a/../other"] {
            XCTAssertNil(BeholderPeople.evidenceURL(address))
        }
    }

    @MainActor private func finished(_ model: BeholderModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.searching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.searching)
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

@testable import AegisApp
import XCTest

final class BeholderCorrelationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testConservativeIdentifierNormalization() throws {
        let expected = try XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone))
        for input in ["0400 000 001", "(04) 0000 0001", "61400000001", "tel:0400-000-001"] {
            XCTAssertEqual(BeholderIdentifier(input: input, kind: .phone, region: .australia), expected)
        }
        XCTAssertNil(BeholderIdentifier(input: "0400 000 001", kind: .phone))
        for input in ["12345", "123456", "KFC AU", "+61 (0)400 000 001", "+610400000001", "+61 400000001\u{2028}"] {
            XCTAssertNil(BeholderIdentifier(input: input, kind: .phone, region: .australia))
        }
        XCTAssertEqual(BeholderIdentifier(input: "mailto:Example+tag@EXAMPLE.COM", kind: .email)?.value, "Example+tag@example.com")
        XCTAssertNotEqual(
            BeholderIdentifier(input: "a+b@example.com", kind: .email),
            BeholderIdentifier(input: "a@example.com", kind: .email)
        )
        XCTAssertNotEqual(
            BeholderIdentifier(input: "Example@example.com", kind: .email),
            BeholderIdentifier(input: "example@example.com", kind: .email)
        )
        XCTAssertNil(BeholderIdentifier(input: "example@example.com?subject=private", kind: .email))
        let roundtrip = try JSONDecoder().decode(BeholderIdentifier.self, from: JSONEncoder().encode(expected))
        XCTAssertEqual(roundtrip, expected)
        XCTAssertThrowsError(try JSONDecoder().decode(BeholderIdentifier.self, from: Data(#"{"kind":"phone","value":"0400"}"#.utf8)))
    }

    func testPublicFieldOnlyAndNoBiographyIdentityInference() {
        let data = Data(
            #"{"login":"example","email":"example@example.com","bio":"Contact someone else at other@example.com or +61 400 000 002"}"#
                .utf8
        )
        let finding = BeholderClient.parse(.init(data: data, status: 200), provider: .github, username: "example", now: date)
        XCTAssertEqual(finding.fields["Public email"], "example@example.com")
        var store = BeholderCorrelation()
        XCTAssertTrue(store.observe(username: "example", finding: finding))
        XCTAssertEqual(store.evidence.count, 1)
        XCTAssertEqual(store.evidence.first?.identifier.value, "example@example.com")
        XCTAssertEqual(store.evidence.first?.origin, .publicField)
        XCTAssertEqual(store.evidence.first?.source, finding.sourceURL)
        XCTAssertEqual(store.evidence.first?.observedAt, date)
    }

    func testLocalEmailAndPhoneOverlapsAreLeadsAndNeverMergePeople() throws {
        var store = BeholderCorrelation()
        var people = BeholderPeople()
        let personID = try people.create("Example Alex")
        let otherID = try people.create("Example Sam")
        let phone = try XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone))
        let mail = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for name in ["example-one", "example-two", "example-three"] {
            XCTAssertTrue(store.observe(username: name, finding: candidate(name)))
            try store.record(accountID: "github:" + name, identifier: phone, source: "https://example.com/" + name, now: date)
        }
        try store.record(accountID: "github:example-two", identifier: mail, source: "https://example.com/contact", now: date)
        try store.identify(personID: personID, identifier: phone, source: "https://example.com/person", now: date)
        try store.identify(personID: personID, identifier: mail, source: "https://example.com/person", now: date)
        // A shared business number can legitimately lead to multiple people; no identity assertion is made.
        try store.identify(personID: otherID, identifier: phone, source: "https://example.com/business", now: date)
        let person = try XCTUnwrap(people.people.first)
        let leads = store.leads(for: person)
        XCTAssertEqual(leads.map(\.id), ["github:example-two", "github:example-one", "github:example-three"])
        XCTAssertEqual(leads.first?.identifierCount, 2)
        XCTAssertEqual(leads.first?.overlaps.first?.referenceURL.absoluteString, "https://example.com/person")
        XCTAssertEqual(leads, store.leads(for: person))
        XCTAssertTrue(people.people.allSatisfy(\.links.isEmpty))
        XCTAssertEqual(store.leads(for: people.people[1]).count, 3)
    }

    func testOnlySupportedLinksSeedMatchesAndRuledOutAccountsStayExcluded() throws {
        var store = BeholderCorrelation()
        var people = BeholderPeople()
        let id = try people.create("Example Person")
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for name in ["example-one", "example-two", "example-three"] {
            XCTAssertTrue(store.observe(username: name, finding: candidate(name)))
            try store.record(accountID: "github:" + name, identifier: identifier, source: "https://example.com/" + name)
        }
        try people.link(
            personID: id,
            username: "example-one",
            finding: candidate("example-one"),
            assessment: .possible,
            reason: "Example evidence",
            evidence: "https://example.com/one"
        )
        XCTAssertTrue(store.leads(for: people.people[0]).isEmpty)
        try people.link(
            personID: id,
            username: "example-one",
            finding: candidate("example-one"),
            assessment: .supported,
            reason: "Example reviewed evidence",
            evidence: "https://example.com/one"
        )
        XCTAssertEqual(store.leads(for: people.people[0]).count, 2)
        try people.link(
            personID: id,
            username: "example-two",
            finding: candidate("example-two"),
            assessment: .ruledOut,
            reason: "Example different owner",
            evidence: ""
        )
        XCTAssertEqual(store.leads(for: people.people[0]).map(\.id), ["github:example-three"])
    }

    func testRefreshRevokesStructuredEvidenceAndUnsuccessfulChecksCannotProduceLeads() throws {
        var store = BeholderCorrelation()
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        let person = BeholderPeople.Person(id: UUID(), name: "Example Person")
        try store.identify(personID: person.id, identifier: identifier, source: "https://example.com/person", now: date)
        var finding = candidate("example")
        finding.fields["Public email"] = identifier.value
        XCTAssertTrue(store.observe(username: "example", finding: finding))
        XCTAssertEqual(store.leads(for: person).count, 1)
        finding.status = .queued; finding.checkedAt = nil
        XCTAssertTrue(store.observe(username: "example", finding: finding))
        XCTAssertTrue(store.leads(for: person).isEmpty)
        XCTAssertTrue(store.evidence.isEmpty)
        finding = candidate("example")
        XCTAssertTrue(store.observe(username: "example", finding: finding))
        XCTAssertTrue(store.leads(for: person).isEmpty)
        try store.record(accountID: "github:example", identifier: identifier, source: "https://example.com/recorded", now: date)
        finding.status = .noResult
        XCTAssertTrue(store.observe(username: "example", finding: finding))
        XCTAssertEqual(store.evidence.count, 1) // The owner's dated observation is preserved, but inactive.
        XCTAssertTrue(store.leads(for: person).isEmpty)
    }

    func testCapsDedupAndEvidenceRemoval() throws {
        var store = BeholderCorrelation()
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for index in 0 ..< BeholderCorrelation.accountLimit {
            let name = "example-\(index)"
            XCTAssertTrue(store.observe(username: name, finding: candidate(name)))
        }
        XCTAssertFalse(store.observe(username: "example-over", finding: candidate("example-over")))
        XCTAssertTrue(store.observe(username: "example-0", finding: candidate("example-0")))
        for _ in 0 ..< 2 {
            try store.record(accountID: "github:example-0", identifier: identifier, source: "https://example.com/evidence")
        }
        XCTAssertEqual(store.evidence.count, 1)
        XCTAssertThrowsError(try store.record(accountID: "missing", identifier: identifier, source: "https://example.com/evidence"))
        XCTAssertThrowsError(try store.record(
            accountID: "github:example-0",
            identifier: identifier,
            source: "https://example.com@evil.example.com"
        ))
        try store.removeEvidence(XCTUnwrap(store.evidence.first?.id))
        XCTAssertTrue(store.evidence.isEmpty)
    }

    @MainActor func testCrossSearchArchiveExportAndClearWithoutIdentifierRequests() async throws {
        let model = BeholderModel(client: CorrelationClient())
        model.selected = [.github]
        for name in ["example-one", "example-two"] {
            model.query = name; model.start()
            for _ in 0 ..< 100 where model.searching {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(model.searching)
        }
        XCTAssertEqual(model.correlation.accounts.count, 2)
        XCTAssertEqual(model.correlation.evidence.count, 2)
        let id = try model.people.create("Example Person")
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        try model.correlation.identify(personID: id, identifier: identifier, source: "https://example.com/person")
        XCTAssertEqual(model.correlation.leads(for: model.people.people[0]).count, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: model.export()) as? [String: Any])
        XCTAssertEqual(json["schema"] as? Int, 4)
        XCTAssertNotNil(json["correlation"])
        model.clear()
        XCTAssertTrue(model.correlation.accounts.isEmpty)
        XCTAssertTrue(model.correlation.hints.isEmpty)
    }

    private func candidate(_ name: String) -> BeholderFinding {
        BeholderFinding(provider: .github, status: .candidate, checkedAt: date, sourceURL: BeholderProvider.github.endpoint(name))
    }
}

private struct CorrelationClient: BeholderSearching {
    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        BeholderFinding(
            provider: provider,
            status: .candidate,
            checkedAt: Date(),
            sourceURL: provider.endpoint(username),
            fields: ["Public email": "example@example.com"]
        )
    }
}

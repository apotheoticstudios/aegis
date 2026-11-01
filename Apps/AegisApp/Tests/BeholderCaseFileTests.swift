@testable import Aegis
import XCTest

final class BeholderCaseFileTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let username = "ExampleAlex"

    func testSchema4RoundtripPreservesUUIDsAndOriginalSnapshots() throws {
        let data = try fixture()
        let original = try BeholderCaseFile.decode(data)
        let second = try BeholderCaseFile.decode(BeholderCaseFile.encode(
            username: original.username, findings: original.findings, people: original.people,
            correlation: original.correlation, exportedAt: original.exportedAt
        ))
        XCTAssertEqual(original, second)
        XCTAssertEqual(second.schema, 4)
        XCTAssertEqual(second.correlation.accounts.count, 1)
        XCTAssertEqual(second.correlation.evidence.count, 2)
        XCTAssertEqual(second.correlation.hints.count, 1)
        XCTAssertTrue(second.provenanceNote.contains("claims in a file"))
        XCTAssertTrue(second.provenanceNote.contains("not independently verified"))
        XCTAssertEqual(try BeholderCaseFile.decode(data), second)
        let json = try object(data)
        XCTAssertEqual(json["warning"] as? String, BeholderCaseFile.provenanceNote)
    }

    func testSchema3WithoutCorrelationRestoresPeopleAndLegacyAccess() throws {
        var json = try object(fixture())
        json["schema"] = 3
        json.removeValue(forKey: "correlation")
        var findings = try XCTUnwrap(json["findings"] as? [[String: Any]])
        findings[0].removeValue(forKey: "access")
        json["findings"] = findings
        let snapshot = try decode(json)
        XCTAssertEqual(snapshot.schema, 3)
        XCTAssertNil(snapshot.findings[0].access)
        XCTAssertEqual(snapshot.people.people.count, 1)
        XCTAssertTrue(snapshot.correlation.accounts.isEmpty)
        XCTAssertTrue(snapshot.correlation.evidence.isEmpty)
        XCTAssertTrue(snapshot.correlation.hints.isEmpty)
    }

    func testPeopleOnlyCaseBeforeFirstSearch() throws {
        var people = BeholderPeople()
        let personID = try people.create("Example Person")
        var correlation = BeholderCorrelation()
        try correlation.identify(
            personID: personID, identifier: XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email)),
            source: "https://example.com/person", now: date
        )
        let data = try BeholderCaseFile.encode(
            username: "", findings: [], people: people, correlation: correlation, exportedAt: date
        )
        let snapshot = try BeholderCaseFile.decode(data)
        XCTAssertEqual(snapshot.username, "")
        XCTAssertEqual(snapshot.people, people)
        XCTAssertEqual(snapshot.correlation, correlation)
        var json = try object(fixture()); json["username"] = ""
        XCTAssertThrowsError(try decode(json))
    }

    func testRejectsUnsupportedVersionsMissingCorrelationAndUnknownKeys() throws {
        let base = try object(fixture())
        for schema in [0, 2, 5, true] as [Any] {
            var json = base; json["schema"] = schema
            XCTAssertThrowsError(try decode(json))
        }
        var json = base; json.removeValue(forKey: "correlation")
        XCTAssertThrowsError(try decode(json))
        json = base; json["schema"] = 3
        XCTAssertThrowsError(try decode(json))
        json = base; json["run"] = "untrusted content"
        XCTAssertThrowsError(try decode(json))
        XCTAssertThrowsError(try BeholderCaseFile.decode(Data("not JSON".utf8)))
    }

    func testRejectsTamperedSourcesAccessStatusesAndHandles() throws {
        for change: [String: Any] in [
            ["sourceURL": "https://example.com/unrelated"], ["sourceURL": "https://api.github.com/users/OtherExample"],
            ["sourceURL": "https://api.github.com/users/ExampleAlex?extra=1"], ["checkedAt": NSNull()],
            ["access": "manual"], ["status": "manual"], ["status": "invented"],
            ["preparedProfileURL": "https://example.com/profile"], ["fields": ["Handle": "OtherExample"]],
        ] {
            var json = try object(fixture())
            var findings = try XCTUnwrap(json["findings"] as? [[String: Any]])
            findings[0].merge(change) { _, new in new }; json["findings"] = findings
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testManualProfilesRemainUncheckedAndCannotBecomeAutomatic() throws {
        let manual = try XCTUnwrap(BeholderProvider.instagram.manualFinding(username))
        let data = try BeholderCaseFile.encode(
            username: username, findings: [manual], people: BeholderPeople(), correlation: BeholderCorrelation(), exportedAt: date
        )
        XCTAssertEqual(try BeholderCaseFile.decode(data).findings, [manual])
        for change: [String: Any] in [
            ["checkedAt": "2027-01-15T08:00:00Z"], ["status": "candidate"], ["access": "automatic"],
            ["preparedProfileURL": "https://www.instagram.com/OtherExample/"],
        ] {
            var json = try object(data)
            var findings = try XCTUnwrap(json["findings"] as? [[String: Any]])
            findings[0].merge(change) { _, new in new }; json["findings"] = findings
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testRefreshStatesWithNoCheckTimeCanReopen() throws {
        for status: BeholderFinding.Status in [.queued, .checking, .cancelled] {
            var correlation = BeholderCorrelation()
            XCTAssertEqual(correlation.observe(username: username, finding: candidate()), .recorded)
            let finding = BeholderFinding(provider: .github, status: status, sourceURL: BeholderProvider.github.endpoint(username))
            XCTAssertEqual(correlation.observe(username: username, finding: finding), .recorded)
            let data = try BeholderCaseFile.encode(
                username: username, findings: [finding], people: BeholderPeople(), correlation: correlation, exportedAt: date
            )
            let account = try BeholderCaseFile.decode(data).correlation.accounts[0]
            XCTAssertEqual(account.finding.status, .candidate)
            XCTAssertEqual(account.latestAttempt?.finding.status, status)
        }
    }

    func testRejectsForgedAccountKeysForeignReferencesAndDuplicateIDs() throws {
        let base = try object(fixture())
        for key in ["id", "username", "accountKey"] {
            var json = base; var store = try XCTUnwrap(json["correlation"] as? [String: Any])
            var accounts = try XCTUnwrap(store["accounts"] as? [[String: Any]])
            accounts[0][key] = key == "username" ? "OtherExample" : "github:OtherExample"
            store["accounts"] = accounts; json["correlation"] = store
            XCTAssertThrowsError(try decode(json))
        }
        for (collection, field) in [("evidence", "accountID"), ("hints", "personID")] {
            var json = base; var store = try XCTUnwrap(json["correlation"] as? [String: Any])
            var entries = try XCTUnwrap(store[collection] as? [[String: Any]])
            entries[0][field] = field == "personID" ? UUID().uuidString : "github:OtherExample"
            store[collection] = entries; json["correlation"] = store
            XCTAssertThrowsError(try decode(json))
        }
        for collection in ["accounts", "evidence", "hints"] {
            var json = base; var store = try XCTUnwrap(json["correlation"] as? [String: Any])
            var entries = try XCTUnwrap(store[collection] as? [[String: Any]])
            entries.append(entries[0]); store[collection] = entries; json["correlation"] = store
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testRejectsForgedPublicEvidenceAndInvalidIdentifiers() throws {
        for change: [String: Any] in [
            ["source": "https://example.com/elsewhere"], ["observedAt": "2027-01-16T08:00:00Z"],
            ["identifier": ["kind": "email", "value": "other@example.com"]],
            ["identifier": ["kind": "phone", "value": "0400 000 001"]],
            ["identifier": ["kind": "email", "value": "example@EXAMPLE.COM"]],
            ["source": "file:///example"], ["source": "https://localhost/example"],
            ["source": "https://example.com@other.example.com/"],
        ] {
            var json = try object(fixture()); var store = try XCTUnwrap(json["correlation"] as? [String: Any])
            var evidence = try XCTUnwrap(store["evidence"] as? [[String: Any]])
            evidence[0].merge(change) { _, new in new }; store["evidence"] = evidence; json["correlation"] = store
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testRestorationRejectsPeopleConflictsWithoutRegeneratingRecords() throws {
        let snapshot = try BeholderCaseFile.decode(fixture())
        let person = try XCTUnwrap(snapshot.people.people.first)
        XCTAssertEqual(try BeholderPeople.restoring([person]).people, [person])
        XCTAssertThrowsError(try BeholderPeople.restoring([person, person]))
        var other = BeholderPeople.Person(id: UUID(), name: "Example Other", links: person.links)
        let link = try XCTUnwrap(person.links.first)
        other.links = [BeholderPeople.AccountLink(
            id: UUID(), username: link.username, finding: link.finding, assessment: .supported,
            reason: link.reason, evidenceURL: link.evidenceURL, assessedAt: date
        )]
        XCTAssertThrowsError(try BeholderPeople.restoring([person, other]))
        var json = try object(fixture()); var people = try XCTUnwrap(json["people"] as? [[String: Any]])
        var links = try XCTUnwrap(people[0]["links"] as? [[String: Any]])
        links[0]["reason"] = "short"; people[0]["links"] = links; json["people"] = people
        XCTAssertThrowsError(try decode(json))
        XCTAssertEqual(snapshot.people.people, [person])
    }

    func testEnforcesByteCollectionAndTextBounds() throws {
        XCTAssertThrowsError(try BeholderCaseFile.decode(Data(repeating: 32, count: BeholderCaseFile.byteLimit + 1))) {
            XCTAssertEqual($0 as? BeholderCaseFile.Problem, .capacity)
        }
        let base = try object(fixture())
        for (collection, count) in [("accounts", 501), ("evidence", 2001), ("hints", 501)] {
            var json = base; var store = try XCTUnwrap(json["correlation"] as? [String: Any])
            let sample = try XCTUnwrap((store[collection] as? [[String: Any]])?.first)
            store[collection] = Array(repeating: sample, count: count); json["correlation"] = store
            XCTAssertThrowsError(try decode(json)) { XCTAssertEqual($0 as? BeholderCaseFile.Problem, .capacity) }
        }
        var tooMany = base
        let person = try XCTUnwrap((base["people"] as? [[String: Any]])?.first)
        tooMany["people"] = Array(repeating: person, count: 51)
        XCTAssertThrowsError(try decode(tooMany)) { XCTAssertEqual($0 as? BeholderCaseFile.Problem, .capacity) }
        var personWithLinks = person
        let link = try XCTUnwrap((person["links"] as? [[String: Any]])?.first)
        personWithLinks["links"] = Array(repeating: link, count: 101)
        tooMany["people"] = [personWithLinks]
        XCTAssertThrowsError(try decode(tooMany)) { XCTAssertEqual($0 as? BeholderCaseFile.Problem, .capacity) }
        for name in [String(repeating: "x", count: 81), "Example\nPerson", "Example\u{202E}Person"] {
            var json = base; var people = try XCTUnwrap(json["people"] as? [[String: Any]])
            people[0]["name"] = name; json["people"] = people
            XCTAssertThrowsError(try decode(json))
        }
        var json = base; var findings = try XCTUnwrap(json["findings"] as? [[String: Any]])
        findings[0]["fields"] = ["Bio": String(repeating: "x", count: 1001)]; json["findings"] = findings
        XCTAssertThrowsError(try decode(json))
    }

    func testRejectsInvalidDatesAndMalformedCollectionShapes() throws {
        for value in ["not a date", "1969-12-31T23:59:59Z", "10000-01-01T00:00:00Z"] {
            var json = try object(fixture()); json["exportedAt"] = value
            XCTAssertThrowsError(try decode(json))
        }
        for key in ["findings", "people", "correlation"] {
            var json = try object(fixture()); json[key] = "unexpected"
            XCTAssertThrowsError(try decode(json))
        }
        var json = try object(fixture()); json["username"] = "example@example.com"
        XCTAssertThrowsError(try decode(json))
    }

    private func fixture() throws -> Data {
        var people = BeholderPeople()
        let personID = try people.create("Example Person")
        let finding = candidate()
        try people.link(
            personID: personID, username: username, finding: finding, assessment: .supported,
            reason: "Example owner evidence", evidence: "https://example.com/person", now: date
        )
        var correlation = BeholderCorrelation()
        XCTAssertEqual(correlation.observe(username: username, finding: finding), .recorded)
        let phone = try XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone))
        try correlation.record(accountID: "github:examplealex", identifier: phone, source: "https://example.com/account", now: date)
        try correlation.identify(personID: personID, identifier: phone, source: "https://example.com/person", now: date)
        return try BeholderCaseFile.encode(
            username: username, findings: [finding], people: people, correlation: correlation, exportedAt: date
        )
    }

    private func candidate() -> BeholderFinding {
        BeholderFinding(
            provider: .github, status: .candidate, checkedAt: date, sourceURL: BeholderProvider.github.endpoint(username),
            fields: ["Handle": username, "Public email": "example@example.com"]
        )
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> BeholderCaseFile.Snapshot {
        try BeholderCaseFile.decode(JSONSerialization.data(withJSONObject: json))
    }
}

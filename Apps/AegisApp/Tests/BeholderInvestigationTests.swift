@testable import Aegis
import XCTest

final class BeholderInvestigationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlySupportedAccountIdentifiersJoinThePersonReferences() throws {
        var people = BeholderPeople(), store = BeholderCorrelation()
        let personID = try people.create("Example Alex")
        for (name, assessment) in [
            ("example-supported", BeholderPeople.Assessment.supported),
            ("example-possible", .possible),
            ("example-ruledout", .ruledOut),
        ] {
            let finding = candidate(name, email: name + "@example.com")
            store.observe(username: name, finding: finding)
            try people.link(
                personID: personID,
                username: name,
                finding: finding,
                assessment: assessment,
                reason: "Example public author evidence",
                evidence: "https://example.com/author",
                now: date
            )
        }
        let phone = try XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone))
        try store.identify(personID: personID, identifier: phone, source: "https://example.com/contact", now: date)
        let person = try XCTUnwrap(people.people.first)
        let summary = BeholderInvestigation.summarize(person, people: people, store: store)
        XCTAssertEqual(Set(summary.details.map(\.identifier.value)), ["example-supported@example.com", phone.value])
        XCTAssertTrue(summary.details.allSatisfy { $0.date == date })
        XCTAssertTrue(summary.details.contains { $0.origin == "Reference recorded by you" })
        XCTAssertTrue(summary.details.contains { $0.origin.contains("Published on GitHub") })
        XCTAssertEqual(person.links.count, 3)
    }

    func testSharedReferencesAndExactLeadsRemainSeparateFromIdentity() throws {
        var people = BeholderPeople(), store = BeholderCorrelation()
        let alex = try people.create("Example Alex"), jamie = try people.create("Example Jamie")
        let email = try XCTUnwrap(BeholderIdentifier(input: "shared@example.com", kind: .email))
        for id in [alex, jamie] {
            try store.identify(personID: id, identifier: email, source: "https://example.com/reference", now: date)
        }
        store.observe(username: "example-lead", finding: candidate("example-lead", email: email.value))
        store.observe(username: "example-nameonly", finding: candidate("example-nameonly"))
        let before = people
        let person = try XCTUnwrap(people.people.first)
        let summary = BeholderInvestigation.summarize(person, people: people, store: store)
        XCTAssertEqual(summary.details.first?.sharedWith, ["Example Jamie"])
        XCTAssertEqual(summary.leads.map(\.account.id), ["github:example-lead"])
        XCTAssertEqual(people, before)
        XCTAssertTrue(person.links.isEmpty)
    }

    func testHistoricalAndPendingReferencesKeepTheirSourceTimes() throws {
        var people = BeholderPeople(), store = BeholderCorrelation()
        let id = try people.create("Example Alex"), finding = candidate("example", email: "example@example.com")
        store.observe(username: "example", finding: finding)
        try people.link(
            personID: id,
            username: "example",
            finding: finding,
            assessment: .supported,
            reason: "Example public author evidence",
            evidence: "https://example.com/source",
            now: date
        )
        let phone = try XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone))
        try store.record(accountID: "github:example", identifier: phone, source: "https://example.com/contact", now: date)
        var absent = finding; absent.status = .noResult
        store.observe(username: "example", finding: absent)
        store.observe(username: "example", finding: .init(provider: .github, status: .queued, sourceURL: finding.sourceURL))
        let person = try XCTUnwrap(people.people.first)
        let summary = BeholderInvestigation.summarize(person, people: people, store: store)
        XCTAssertEqual(summary.details.count, 1, "Revoked public fields do not remain current person details")
        let detail = try XCTUnwrap(summary.details.first)
        XCTAssertTrue(detail.historical); XCTAssertTrue(detail.pending)
        XCTAssertEqual(detail.date, date)
        XCTAssertEqual(detail.identifier, phone)
    }

    func testOverviewCapsAreDeterministicAndReportTheFullCounts() throws {
        var people = BeholderPeople(), store = BeholderCorrelation()
        let id = try people.create("Example Alex")
        let email = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for number in 0 ..< 60 {
            try store.identify(personID: id, identifier: email, source: "https://example.com/reference/\(number)", now: date)
        }
        for number in 0 ..< 25 {
            let handle = "example-\(number)"
            store.observe(username: handle, finding: candidate(handle, email: email.value))
        }
        for number in 0 ..< 30 {
            let other = try XCTUnwrap(BeholderIdentifier(input: "other-\(number)@example.com", kind: .email))
            try store.identify(personID: id, identifier: other, source: "https://example.com/other", now: date)
        }
        let person = try XCTUnwrap(people.people.first)
        let first = BeholderInvestigation.summarize(person, people: people, store: store)
        let second = BeholderInvestigation.summarize(person, people: people, store: store)
        XCTAssertEqual(first.detailCount, 90); XCTAssertEqual(first.identifierCount, 31)
        XCTAssertEqual(first.identifiers.count, 20)
        XCTAssertTrue(first.identifiers.allSatisfy { $0.references.count <= 5 })
        XCTAssertEqual(first.identifiers.first?.referenceCount, 60)
        XCTAssertEqual(first.leadCount, 25); XCTAssertEqual(first.leads.count, 20)
        XCTAssertEqual(first.details.map(\.id), second.details.map(\.id))
        XCTAssertEqual(first.leads.map(\.id), second.leads.map(\.id))
    }

    @MainActor func testSavePossibleNeverOverwritesAnAssessmentOrMakesARequest() async throws {
        let client = InvestigationNoNetwork(), model = BeholderModel(client: client)
        let id = try model.people.create("Example Alex"), finding = candidate("example")
        XCTAssertTrue(try model.savePossible(personID: id, username: "example", finding: finding))
        let link = try XCTUnwrap(model.people.people.first?.links.first)
        XCTAssertEqual(link.assessment, .possible); XCTAssertNil(link.evidenceURL)
        for assessment in [BeholderPeople.Assessment.supported, .ruledOut] {
            try model.people.reassess(
                personID: id,
                linkID: link.id,
                assessment: assessment,
                reason: "Example reviewed account evidence",
                evidence: "https://example.com/source"
            )
            let before = model.people, revision = model.caseRevision
            XCTAssertFalse(try model.savePossible(personID: id, username: "example", finding: finding))
            XCTAssertEqual(model.people, before); XCTAssertEqual(model.caseRevision, revision)
        }
        let manual = try XCTUnwrap(BeholderProvider.instagram.manualFinding("ExampleAlex"))
        XCTAssertTrue(try model.savePossible(personID: id, username: "ExampleAlex", finding: manual))
        let variant = try XCTUnwrap(BeholderProvider.instagram.manualFinding("examplealex"))
        XCTAssertFalse(try model.savePossible(personID: id, username: "examplealex", finding: variant))
        let other = try model.people.create("Example Jamie"), otherFinding = candidate("example-other")
        try model.people.link(
            personID: other,
            username: "example-other",
            finding: otherFinding,
            assessment: .supported,
            reason: "Example reviewed author source",
            evidence: "https://example.com/other"
        )
        XCTAssertThrowsError(try model.savePossible(personID: id, username: "example-other", finding: otherFinding))
        let requestCount = await client.count
        XCTAssertEqual(requestCount, 0)
    }

    private func candidate(_ name: String, email: String? = nil) -> BeholderFinding {
        var fields = ["Display name": "Example Alex"]
        if let email {
            fields["Public email"] = email
        }
        return BeholderFinding(
            provider: .github,
            status: .candidate,
            checkedAt: date,
            sourceURL: BeholderProvider.github.endpoint(name),
            fields: fields
        )
    }
}

extension BeholderInvestigationTests {
    @MainActor func testCamelCaseManualProvidersPreserveAssessmentsAndExcludeOtherPeopleFromLeads() throws {
        for provider in [BeholderProvider.linkedIn, .soundCloud] {
            let model = BeholderModel(client: InvestigationNoNetwork())
            let alex = try model.people.create("Example Alex"), jamie = try model.people.create("Example Jamie")
            let finding = try XCTUnwrap(provider.manualFinding("ExampleAlex"))
            for assessment in [BeholderPeople.Assessment.supported, .ruledOut] {
                try model.people.link(
                    personID: alex,
                    username: "ExampleAlex",
                    finding: finding,
                    assessment: assessment,
                    reason: "Example reviewed author source",
                    evidence: "https://example.com/author"
                )
                let before = model.people
                for handle in ["ExampleAlex", "examplealex"] {
                    let variant = try XCTUnwrap(provider.manualFinding(handle))
                    XCTAssertFalse(try model.savePossible(personID: alex, username: handle, finding: variant))
                    XCTAssertEqual(model.people, before)
                    if assessment == .supported {
                        XCTAssertThrowsError(try model.savePossible(personID: jamie, username: handle, finding: variant))
                    }
                }
            }
            try model.people.link(
                personID: alex,
                username: "ExampleAlex",
                finding: finding,
                assessment: .supported,
                reason: "Example reviewed author source",
                evidence: "https://example.com/author"
            )
            let key = BeholderPeople.supportKey(provider: provider, username: "ExampleAlex")
            XCTAssertEqual(key, provider.rawValue + ":examplealex")
            XCTAssertEqual(model.people.people.first?.links.first?.supportKey, key)
            let email = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
            try model.correlation.identify(personID: jamie, identifier: email, source: "https://example.com/author")
            for handle in ["ExampleAlex", "examplealex"] {
                let variant = try XCTUnwrap(provider.manualFinding(handle))
                model.correlation.observe(username: handle, finding: variant)
                try model.correlation.record(
                    accountID: BeholderCorrelation.key(provider, handle),
                    identifier: email,
                    source: "https://example.com/contact"
                )
            }
            let person = try XCTUnwrap(model.people.people.first { $0.id == jamie })
            XCTAssertTrue(model.correlation.leads(for: person, people: model.people.people).isEmpty)
        }
    }

    @MainActor func testLeadReviewIsBoundToItsChosenPerson() {
        let alex = UUID(), jamie = UUID()
        let target = BeholderPeopleView.Target(username: "example", finding: candidate("example"), preferredPersonID: alex)
        XCTAssertTrue(target.permits(alex)); XCTAssertFalse(target.permits(jamie)); XCTAssertFalse(target.permits(nil))
        let unbound = BeholderPeopleView.Target(username: "example", finding: candidate("example"))
        XCTAssertTrue(unbound.permits(jamie)); XCTAssertFalse(unbound.permits(nil))
    }
}

private actor InvestigationNoNetwork: BeholderSearching {
    private(set) var count = 0
    func lookup(_ provider: BeholderProvider, username _: String) async -> BeholderFinding {
        count += 1
        XCTFail("An overview or local assessment must not make a request")
        return BeholderFinding(provider: provider, status: .unavailable)
    }
}

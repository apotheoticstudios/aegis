@testable import Aegis
import XCTest

final class BeholderCaseSearchTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testStructuredNamesMatchButBiographyMentionsDoNot() throws {
        var store = BeholderCorrelation()
        for (handle, fields) in [
            ("example-one", ["Display name": "Example Alex"]),
            ("example-two", ["Display name": "Alex Example"]),
            ("example-three", ["Bio": "My friend Example Alex uses this account"]),
            ("example-four", ["Display name": "Example Alexander"]),
        ] {
            store.observe(username: handle, finding: candidate(handle, fields: fields))
        }
        let report = try BeholderCaseSearch.compute(input: "Example Alex", kind: .name, store: store, people: .init())
        XCTAssertEqual(report.hits.map(\.id), ["github:example-one", "github:example-two"])
        XCTAssertEqual(report.hits[0].reasons[0].source, BeholderProvider.github.endpoint("example-one"))
        XCTAssertEqual(report.hits[1].reasons[0].order, 1)
        let partial = try BeholderCaseSearch.compute(input: "Alex", kind: .name, store: store, people: .init())
        XCTAssertEqual(partial.hits.map(\.id), ["github:example-one", "github:example-two"])
        XCTAssertTrue(partial.hits.allSatisfy { $0.reasons[0].label.contains("Partial") })
        let repeated = try BeholderCaseSearch.compute(input: "Example Example", kind: .name, store: store, people: .init())
        XCTAssertTrue(repeated.hits.isEmpty)
    }

    func testPeopleWithoutAccountsAppearByLabelAndRecordedReference() throws {
        var people = BeholderPeople(), store = BeholderCorrelation()
        let person = try people.create("Example Alex")
        let name = try BeholderCaseSearch.compute(input: "Alex Example", kind: .name, store: store, people: people)
        XCTAssertEqual(name.people.map(\.id), [person])
        XCTAssertEqual(name.total, 0)

        let phone = try XCTUnwrap(BeholderIdentifier(input: "+61 400 000 001", kind: .phone))
        try store.identify(personID: person, identifier: phone, source: "https://example.com/reference", now: date)
        let result = try BeholderCaseSearch.compute(
            input: "0400 000 001", kind: .phone, region: .australia, store: store, people: people
        )
        let match = try XCTUnwrap(result.people.first)
        XCTAssertEqual(match.id, person)
        XCTAssertEqual(match.reason.value, phone.value)
        XCTAssertEqual(match.reason.source?.absoluteString, "https://example.com/reference")
        XCTAssertEqual(match.reason.date, date)
        XCTAssertEqual(result.total, 0)
    }

    func testMatchingAccountFindsOnlyItsSupportedInvestigation() throws {
        var people = BeholderPeople()
        let supported = try people.create("Example Alex")
        let possible = try people.create("Example Jamie")
        let ruledOut = try people.create("Example Morgan")
        for (id, assessment) in [(supported, BeholderPeople.Assessment.supported), (possible, .possible), (ruledOut, .ruledOut)] {
            try people.link(
                personID: id, username: "Example", finding: candidate("Example", fields: ["Display name": "Example"]),
                assessment: assessment,
                reason: "Example public reference", evidence: "https://example.com/reference", now: date
            )
        }
        let result = try BeholderCaseSearch.compute(input: "@Example", kind: .username, store: .init(), people: people)
        XCTAssertEqual(result.people.map(\.id), [supported])
        XCTAssertEqual(result.people.first?.reason.source?.absoluteString, "https://example.com/reference")
        XCTAssertEqual(result.hits.map(\.id), ["github:example"])
        let name = try BeholderCaseSearch.compute(input: "Example", kind: .name, store: .init(), people: people)
        XCTAssertEqual(name.people.first?.id, supported)
        XCTAssertEqual(name.people.first?.reason.label, "Supported account matched")
        XCTAssertEqual(name.people.first?.reason.order, 0)
    }

    func testEmailExactAndCaseVariantRemainExplainedAndPlusAddressesDistinct() throws {
        var store = BeholderCorrelation()
        for (handle, value) in [
            ("example-one", "example+tag@example.com"),
            ("example-two", "Example+tag@example.com"),
            ("example-three", "example@example.com"),
        ] {
            store.observe(username: handle, finding: candidate(handle, fields: ["Public email": value]))
        }
        let report = try BeholderCaseSearch.compute(input: "mailto:example+tag@EXAMPLE.COM", kind: .email, store: store, people: .init())
        XCTAssertEqual(report.hits.map(\.id), ["github:example-one", "github:example-two"])
        XCTAssertTrue(report.hits[1].reasons[0].label.contains("case"))
        XCTAssertEqual(report.hits[0].reasons[0].date, date)
        XCTAssertEqual(report.total, 2)
    }

    func testPhoneSearchDoesNotRequireCreatingAPersonAndKeepsHistoricalEvidenceSeparate() throws {
        var store = BeholderCorrelation()
        let phone = try XCTUnwrap(BeholderIdentifier(input: "tel:61400000001", kind: .phone, region: .australia))
        XCTAssertEqual(phone.value, "+61400000001")
        store.observe(username: "example", finding: candidate("example"))
        try store.record(accountID: "github:example", identifier: phone, source: "https://example.com/contact", now: date)
        let result = try BeholderCaseSearch.compute(
            input: "(04) 0000 0001",
            kind: .phone,
            region: .australia,
            store: store,
            people: .init()
        )
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertFalse(result.hits[0].historical)
        var absent = candidate("example"); absent.status = .noResult
        store.observe(username: "example", finding: absent)
        let history = try BeholderCaseSearch.compute(input: "+61 400 000 001", kind: .phone, store: store, people: .init())
        XCTAssertTrue(try XCTUnwrap(history.hits.first).historical)
    }

    func testSupportedOwnerReferencesWorkWithLegacyCasesButPossibleLinksNeverSeed() throws {
        var people = BeholderPeople()
        let person = try people.create("Example Alex")
        var store = BeholderCorrelation()
        let email = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        try store.identify(personID: person, identifier: email, source: "https://example.com/author", now: date)
        try people.link(
            personID: person,
            username: "example",
            finding: candidate("example"),
            assessment: .possible,
            reason: "Example name only",
            evidence: ""
        )
        XCTAssertEqual(try BeholderCaseSearch.compute(input: email.value, kind: .email, store: store, people: people).total, 0)
        try people.link(
            personID: person,
            username: "example",
            finding: candidate("example"),
            assessment: .supported,
            reason: "Example explicit public evidence",
            evidence: "https://example.com/source",
            now: date
        )
        let result = try BeholderCaseSearch.compute(input: email.value, kind: .email, store: store, people: people)
        XCTAssertEqual(result.total, 1)
        XCTAssertTrue(result.hits[0].reasons[0].label.contains("Owner reference"))
        XCTAssertEqual(try BeholderCaseSearch.compute(input: "Example Alex", kind: .name, store: store, people: people).total, 1)
    }

    func testBoundsAndNormalizationCannotBeBypassedByTrimming() throws {
        for input in ["tel:61400000001", "TEL:61 400 000 001", "tel:0400 000 001"] {
            XCTAssertEqual(BeholderIdentifier(input: input, kind: .phone, region: .australia)?.value, "+61400000001")
        }
        for input in ["\t+61400000001", "+61400000001\n", String(repeating: " ", count: 513) + "+61400000001"] {
            XCTAssertNil(BeholderIdentifier(input: input, kind: .phone, region: .australia))
        }
        var store = BeholderCorrelation()
        for index in 0 ..< 110 {
            let handle = "example-\(index)"
            store.observe(username: handle, finding: candidate(handle, fields: ["Display name": "Example Alex"]))
        }
        let a = try BeholderCaseSearch.compute(input: "Example Alex", kind: .name, store: store, people: .init())
        let b = try BeholderCaseSearch.compute(input: "Example Alex", kind: .name, store: store, people: .init())
        XCTAssertEqual(a.total, 110); XCTAssertEqual(a.hits.count, 100); XCTAssertEqual(a.hits.map(\.id), b.hits.map(\.id))
    }

    @MainActor func testModeIsolationMakesNoRequestsAndNeverExportsSearchOnlyIdentifiers() async throws {
        let client = DiscoveryCountingClient()
        let model = BeholderModel(client: client)
        let discovery = model.unifiedSearch
        for (kind, input) in [
            (BeholderCaseSearch.Kind.name, "Example Alex"),
            (.phone, "+61 400 000 099"),
            (.email, "unknown@example.com"),
            (.ip, "203.0.113.1"),
        ] {
            discovery.query = input
            discovery.interpret(as: kind)
            discovery.prepare()
            let requestCount = await client.count()
            XCTAssertEqual(requestCount, 0)
            XCTAssertEqual(model.query, "")
            let exported = try XCTUnwrap(String(data: model.export(), encoding: .utf8))
            XCTAssertFalse(exported.contains(input))
            discovery.interpret(as: .username)
            XCTAssertEqual(discovery.query, input)
            XCTAssertNil(discovery.prepared)
            XCTAssertFalse(discovery.canPrepare)
        }
        discovery.query = "+61 400 000 099"; discovery.prepare()
        discovery.query = "+61 400 000 098"
        XCTAssertNil(discovery.report(in: model), "Editing input cannot leave stale results visible")
    }

    @MainActor func testEditingEvidenceInvalidatesSavedMatchesImmediately() throws {
        let model = BeholderModel(client: DiscoveryCountingClient())
        model.correlation.observe(username: "example", finding: candidate("example", fields: ["Public email": "example@example.com"]))
        let discovery = model.unifiedSearch
        discovery.query = "example@example.com"; discovery.prepare()
        XCTAssertEqual(discovery.report(in: model)?.total, 1)
        let id = try XCTUnwrap(model.correlation.evidence.first?.id)
        model.correlation.removeEvidence(id)
        XCTAssertEqual(discovery.report(in: model)?.total, 0, "A changed case must refresh the cached report")
        XCTAssertNil(discovery.problem)
    }

    @MainActor func testPhoneAndEmailInputsCannotStartAUsernameLookup() async {
        let client = DiscoveryCountingClient()
        let model = BeholderModel(client: client)
        let discovery = model.unifiedSearch
        for value in [
            "0400000001", "61400000001", "0400-000-001", "@0400000001", "tel:0400000001", "example@example.com", "203.0.113.1",
        ] {
            discovery.query = value
            discovery.interpret(as: .username)
            XCTAssertFalse(discovery.canPrepare)
            discovery.prepare()
            XCTAssertNotNil(discovery.problem)
            XCTAssertEqual(model.query, "")
            XCTAssertFalse(model.searching)
            model.query = value
            model.start()
            XCTAssertFalse(model.searching, "The model also rejects bypassing the discovery controls")
            XCTAssertEqual(model.username, "")
            model.query = ""
        }
        let count = await client.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(BeholderCaseSearch.username("@ExampleAlex"), "ExampleAlex")
        XCTAssertEqual(BeholderCaseSearch.username("Example123"), "Example123")
        XCTAssertNil(BeholderCaseSearch.username("ExampleAlex\n"))
        XCTAssertNil(BeholderCaseSearch.username("ExampleAlex\u{2028}"))
    }

    @MainActor func testNewLocalSearchCancelsAnEarlierExplicitUsernameSearch() {
        let model = BeholderModel(client: DiscoveryCountingClient())
        model.query = "ExampleAlex"; model.selected = [.github]; model.start()
        defer { model.cancel() }
        let generation = model.cancellationID
        let discovery = model.unifiedSearch
        XCTAssertEqual(discovery.query, "")
        discovery.query = "Example Alex"; discovery.prepare()
        XCTAssertFalse(model.searching)
        XCTAssertNotEqual(model.cancellationID, generation)
        XCTAssertEqual(model.query, "ExampleAlex")
        XCTAssertEqual(discovery.report(in: model)?.total, 0)
    }

    func testRechecksRetainDatedMatchesAndInitialsDoNotCreateBroadNameMatches() throws {
        var store = BeholderCorrelation()
        store.observe(username: "example", finding: candidate("example", fields: ["Display name": "Example Alex"]))
        store.observe(
            username: "example",
            finding: .init(provider: .github, status: .queued, sourceURL: BeholderProvider.github.endpoint("example"))
        )
        let report = try BeholderCaseSearch.compute(input: "Example Alex", kind: .name, store: store, people: .init())
        XCTAssertEqual(report.total, 1)
        XCTAssertTrue(try XCTUnwrap(report.hits.first).account.pending)
        XCTAssertEqual(report.hits.first?.reasons.first?.date, date)
        store.observe(username: "example-initials", finding: candidate("example-initials", fields: ["Display name": "Alex B Example"]))
        XCTAssertEqual(try BeholderCaseSearch.compute(input: "A B", kind: .name, store: store, people: .init()).total, 0)
        XCTAssertEqual(try BeholderCaseSearch.compute(input: "Alex B", kind: .name, store: store, people: .init()).total, 0)
        XCTAssertEqual(try BeholderCaseSearch.compute(input: "Alex B Example", kind: .name, store: store, people: .init()).total, 1)
    }

    func testManySavedReferencesAreBoundedPerAccount() throws {
        var people = BeholderPeople()
        let person = try people.create("Example Alex")
        try people.link(
            personID: person,
            username: "example",
            finding: candidate("example"),
            assessment: .supported,
            reason: "Example explicit author link",
            evidence: "https://example.com/source",
            now: date
        )
        var store = BeholderCorrelation()
        let email = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for index in 0 ..< 100 {
            try store.identify(personID: person, identifier: email, source: "https://example.com/contact/\(index)", now: date)
        }
        let report = try BeholderCaseSearch.compute(input: email.value, kind: .email, store: store, people: people)
        XCTAssertEqual(report.hits.first?.totalReasons, 100)
        XCTAssertEqual(report.hits.first?.reasons.count, 20)
    }

    private func candidate(_ username: String, fields: [String: String] = [:]) -> BeholderFinding {
        BeholderFinding(
            provider: .github,
            status: .candidate,
            checkedAt: date,
            sourceURL: BeholderProvider.github.endpoint(username),
            fields: fields
        )
    }
}

private actor DiscoveryCountingClient: BeholderSearching {
    private var requests = 0
    func count() -> Int {
        requests
    }

    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        requests += 1
        return BeholderFinding(provider: provider, status: .unavailable, checkedAt: Date(), sourceURL: provider.endpoint(username))
    }
}

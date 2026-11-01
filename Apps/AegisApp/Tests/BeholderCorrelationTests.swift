@testable import Aegis
import AppKit
import SwiftUI
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
        XCTAssertEqual(store.observe(username: "example", finding: finding), .recorded)
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
            XCTAssertEqual(store.observe(username: name, finding: candidate(name)), .recorded)
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
            XCTAssertEqual(store.observe(username: name, finding: candidate(name)), .recorded)
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

    func testOnlyDefiniteRefreshReplacesDatedEvidence() throws {
        var store = BeholderCorrelation()
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        let person = BeholderPeople.Person(id: UUID(), name: "Example Person")
        try store.identify(personID: person.id, identifier: identifier, source: "https://example.com/person", now: date)
        var finding = candidate("example")
        finding.fields["Public email"] = identifier.value
        XCTAssertEqual(store.observe(username: "example", finding: finding), .recorded)
        XCTAssertEqual(store.leads(for: person).count, 1)
        finding.status = .queued; finding.checkedAt = nil
        XCTAssertEqual(store.observe(username: "example", finding: finding), .recorded)
        XCTAssertTrue(store.leads(for: person).isEmpty)
        XCTAssertEqual(store.evidence.count, 1)
        let originalEvidence = store.evidence
        for status in [BeholderFinding.Status.cancelled, .limited, .unavailable] {
            finding.status = status; finding.checkedAt = date.addingTimeInterval(60)
            XCTAssertEqual(store.observe(username: "example", finding: finding), .recorded)
            XCTAssertEqual(store.evidence, originalEvidence)
            XCTAssertEqual(store.accounts.first?.finding.status, .candidate)
            XCTAssertEqual(store.accounts.first?.latestAttempt?.finding.status, status)
            XCTAssertEqual(store.leads(for: person).count, 1)
        }
        finding = candidate("example")
        XCTAssertEqual(store.observe(username: "example", finding: finding), .recorded)
        XCTAssertTrue(store.leads(for: person).isEmpty)
        try store.record(accountID: "github:example", identifier: identifier, source: "https://example.com/recorded", now: date)
        finding.status = .noResult
        XCTAssertEqual(store.observe(username: "example", finding: finding), .recorded)
        XCTAssertEqual(store.evidence.count, 1) // The owner's dated observation is preserved, but inactive.
        XCTAssertTrue(store.leads(for: person).isEmpty)
    }

    func testAnAccountSupportedUnderAnotherPersonIsNotSuggested() throws {
        var store = BeholderCorrelation()
        var people = BeholderPeople()
        let first = try people.create("Example Alex")
        let other = try people.create("Example Sam")
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        store.observe(username: "example", finding: candidate("example"))
        try store.record(accountID: "github:example", identifier: identifier, source: "https://example.com/company")
        try store.identify(personID: first, identifier: identifier, source: "https://example.com/company")
        try people.link(
            personID: other,
            username: "example",
            finding: candidate("example"),
            assessment: .supported,
            reason: "Example reviewed source",
            evidence: "https://example.com/source"
        )
        XCTAssertTrue(store.leads(for: people.people[0], people: people.people).isEmpty)
    }

    @MainActor func testUnsupportedHandleDoesNotReportCapacity() async throws {
        let model = BeholderModel(client: CorrelationClient())
        model.selected = [.github, .instagram]
        for name in ["Example_Alex", "Example.Alex"] {
            model.query = name; model.start()
            for _ in 0 ..< 100 where model.searching {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNil(model.problem)
            XCTAssertEqual(model.findings.first { $0.provider == .github }?.status, .unsupported)
        }
    }

    func testCapsDedupAndEvidenceRemoval() throws {
        var store = BeholderCorrelation()
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        for index in 0 ..< BeholderCorrelation.accountLimit {
            let name = "example-\(index)"
            XCTAssertEqual(store.observe(username: name, finding: candidate(name)), .recorded)
        }
        XCTAssertEqual(store.observe(username: "example-over", finding: candidate("example-over")), .capacity)
        XCTAssertEqual(store.observe(username: "example-0", finding: candidate("example-0")), .recorded)
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

    func testCaseInsensitiveRefreshRetainsConsistentAccountSpelling() {
        var store = BeholderCorrelation()
        XCTAssertEqual(store.observe(username: "Example", finding: candidate("Example")), .recorded)
        XCTAssertEqual(store.observe(username: "example", finding: candidate("example")), .recorded)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].username, "example")
        XCTAssertEqual(store.accounts[0].finding.sourceURL, BeholderProvider.github.endpoint(store.accounts[0].username))
    }

    @MainActor func testSyntheticIdentifierWorkspaceRenders() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else { throw XCTSkip("Opt-in synthetic evidence render") }
        let model = BeholderModel(client: CorrelationClient())
        let personID = try model.people.create("Example Alex")
        var finding = candidate("example")
        finding.fields["Public email"] = "example@example.com"
        model.correlation.observe(username: "example", finding: finding)
        let identifier = try XCTUnwrap(BeholderIdentifier(input: "example@example.com", kind: .email))
        try model.correlation.identify(personID: personID, identifier: identifier, source: "https://example.com/contact", now: date)
        for (name, accountID) in [("leads", nil as String?), ("archive", "github:example")] {
            let size = CGSize(width: 760, height: 620)
            let host = NSHostingView(rootView: BeholderCorrelationView(research: model, personID: personID, accountID: accountID)
                .environment(\.colorScheme, .dark))
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-evidence-\(name).png"))
        }
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
        guard let endpoint = provider.endpoint(username) else { return BeholderFinding(provider: provider, status: .unsupported) }
        return BeholderFinding(
            provider: provider,
            status: .candidate,
            checkedAt: Date(),
            sourceURL: endpoint,
            fields: ["Public email": "example@example.com"]
        )
    }
}

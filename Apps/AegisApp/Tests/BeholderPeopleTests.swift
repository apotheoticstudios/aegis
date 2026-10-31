@testable import Aegis
import AppKit
import SwiftUI
import XCTest

final class BeholderPeopleTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_700_000_000)
    private let reason = "The public profile links to the other account."
    private let evidence = "https://example.com/public-profile"

    func testDifferentHandlesAndSourcesCanBelongToOnePersonWithoutMergingOthers() throws {
        var caseFile = BeholderPeople()
        let alex = try caseFile.create("Example Alex")
        let other = try caseFile.create("Example Alex")
        XCTAssertNotEqual(alex, other)
        try attach(&caseFile, alex, "ExampleAlex", .github)
        try attach(&caseFile, alex, "ExampleWriter", .dev)
        try attach(&caseFile, other, "ExampleAlex", .github)
        XCTAssertEqual(caseFile.people.map(\.links.count), [2, 1])
        XCTAssertEqual(caseFile.people[0].links.map(\.username), ["ExampleAlex", "ExampleWriter"])
        XCTAssertTrue(caseFile.people.flatMap(\.links).allSatisfy { $0.assessment == .possible })
    }

    func testConflictingSupportRequiresReassessmentAndRemainsReversible() throws {
        var caseFile = BeholderPeople()
        let first = try caseFile.create("Example Alex")
        let second = try caseFile.create("Example Bailey")
        try attach(&caseFile, first, "ExampleAlex", .github, .supported)
        XCTAssertThrowsError(try attach(&caseFile, second, "examplealex", .github, .supported))
        try attach(&caseFile, second, "ExampleAlex", .github)
        try attach(&caseFile, first, "ExampleAlex", .github, .ruledOut)
        try attach(&caseFile, second, "ExampleAlex", .github, .supported)
        XCTAssertEqual(caseFile.people.map { $0.links[0].assessment }, [.ruledOut, .supported])
        caseFile.remove(personID: second, linkID: caseFile.people[1].links[0].id)
        XCTAssertTrue(caseFile.people[1].links.isEmpty)
    }

    func testReassessmentPreservesOriginalObservationAndCaseSensitiveSources() throws {
        var caseFile = BeholderPeople()
        let person = try caseFile.create("Example Alex")
        try attach(&caseFile, person, "ExampleAlex", .github)
        let original = caseFile.people[0].links[0]
        let later = observed.addingTimeInterval(3600)
        try caseFile.link(
            personID: person,
            username: "examplealex",
            finding: finding(.github, "examplealex", at: later),
            assessment: .supported,
            reason: reason,
            evidence: evidence,
            now: later
        )
        XCTAssertEqual(caseFile.people[0].links.count, 1)
        let revised = caseFile.people[0].links[0]
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.finding, original.finding)
        XCTAssertEqual(revised.assessedAt, later)
        XCTAssertEqual(revised.finding.checkedAt, observed)
        try attach(&caseFile, person, "ExampleAlex", .hackerNews)
        try attach(&caseFile, person, "examplealex", .hackerNews)
        XCTAssertEqual(caseFile.people[0].links.count, 3)
    }

    func testManualLinksRemainUncheckedEvenWhenOwnerSupportsThem() throws {
        var caseFile = BeholderPeople()
        let person = try caseFile.create("Example Alex")
        let manual = try XCTUnwrap(BeholderProvider.instagram.manualFinding("ExampleAlex"))
        try caseFile.link(
            personID: person,
            username: "ExampleAlex",
            finding: manual,
            assessment: .supported,
            reason: reason,
            evidence: evidence,
            now: observed
        )
        let link = caseFile.people[0].links[0]
        XCTAssertEqual(link.finding.status, .manual)
        XCTAssertNil(link.finding.checkedAt)
        XCTAssertNil(link.finding.sourceURL)
        XCTAssertEqual(link.assessedAt, observed)
        XCTAssertNotNil(link.finding.preparedProfileURL)
    }

    func testInvalidSourcesCannotBecomeEvidence() throws {
        var caseFile = BeholderPeople()
        let person = try caseFile.create("Example Alex")
        for status in [BeholderFinding.Status.queued, .checking, .cancelled, .noResult, .unavailable, .unsupported, .limited] {
            var invalid = finding(.github, "ExampleAlex")
            invalid.status = status
            XCTAssertThrowsError(try caseFile.link(
                personID: person,
                username: "ExampleAlex",
                finding: invalid,
                assessment: .possible,
                reason: reason,
                evidence: ""
            ))
        }
        var forged = finding(.github, "ExampleAlex")
        forged.checkedAt = nil
        XCTAssertThrowsError(try caseFile.link(
            personID: person,
            username: "ExampleAlex",
            finding: forged,
            assessment: .possible,
            reason: reason,
            evidence: ""
        ))
        forged.checkedAt = observed; forged.sourceURL = URL(string: evidence)
        XCTAssertThrowsError(try caseFile.link(
            personID: person,
            username: "ExampleAlex",
            finding: forged,
            assessment: .possible,
            reason: reason,
            evidence: ""
        ))
        XCTAssertTrue(caseFile.people[0].links.isEmpty)
    }

    func testTextURLAndCapacityBounds() throws {
        var caseFile = BeholderPeople()
        for label in ["", " ", "Example\nAlex", "Example\u{202E}Alex", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try caseFile.create(label))
        }
        let person = try caseFile.create("Example Alex")
        for url in [
            "",
            "http://example.com",
            "file:///example",
            "https://example:secret@example.com",
            "https://127.0.0.1",
            "https://example.local",
            "https://example.com:8080",
            "https://example.com/\u{200B}",
            String(repeating: "a", count: 2049),
        ] {
            XCTAssertThrowsError(try caseFile.link(
                personID: person,
                username: "ExampleAlex",
                finding: finding(.github, "ExampleAlex"),
                assessment: .supported,
                reason: reason,
                evidence: url
            ))
        }
        XCTAssertThrowsError(try caseFile.link(
            personID: person,
            username: "ExampleAlex",
            finding: finding(.github, "ExampleAlex"),
            assessment: .possible,
            reason: "why\u{2028}Example",
            evidence: ""
        ))
        for index in 1 ..< 50 {
            try caseFile.create("Example \(index)")
        }
        XCTAssertThrowsError(try caseFile.create("Example Overflow"))
        XCTAssertTrue(caseFile.people[0].links.isEmpty)
    }

    @MainActor func testSearchesPreservePeopleAndExportContainsTheirEvidenceWithoutNewRequests() async throws {
        let client = PeopleSearchSpy()
        let model = BeholderModel(client: client)
        let person = try model.people.create("Example Alex")
        try attach(&model.people, person, "ExampleAlex", .github, .supported)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: model.export()) as? [String: Any])
        XCTAssertEqual(json["schema"] as? Int, 3)
        XCTAssertEqual((json["people"] as? [[String: Any]])?.count, 1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encodedPeople = try JSONSerialization.data(withJSONObject: XCTUnwrap(json["people"]))
        XCTAssertEqual(try decoder.decode([BeholderPeople.Person].self, from: encodedPeople), model.people.people)
        let initialRequests = await client.requests
        XCTAssertEqual(initialRequests, 0)
        model.selected = [.instagram]; model.query = "ExampleOther"; model.start()
        XCTAssertEqual(model.people.people[0].links[0].username, "ExampleAlex")
        let afterManualSearch = await client.requests
        XCTAssertEqual(afterManualSearch, 0)
        model.clear()
        XCTAssertTrue(model.people.people.isEmpty)
    }

    @MainActor func testSyntheticPersonWorkspaceRenders() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in synthetic person-workspace render.")
        }
        let model = BeholderModel()
        let person = try model.people.create("Example Alex")
        try attach(&model.people, person, "ExampleAlex", .github, .supported)
        try attach(&model.people, person, "ExampleWriter", .dev)
        let target = BeholderPeopleView.Target(username: "ExampleOther", finding: finding(.gitlab, "ExampleOther"))
        for (name, view) in [
            ("people", BeholderPeopleView(research: model)),
            ("people-link", BeholderPeopleView(research: model, target: target)),
        ] {
            let size = CGSize(width: 720, height: 820)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(HUD.void).environment(\.colorScheme, .dark))
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
            try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-\(name).png"))
        }
    }

    private func finding(_ provider: BeholderProvider, _ username: String, at: Date? = nil) -> BeholderFinding {
        BeholderFinding(
            provider: provider,
            status: .candidate,
            checkedAt: at ?? observed,
            sourceURL: provider.endpoint(username),
            fields: ["Handle": username, "Display name": "Example Alex"]
        )
    }

    private func attach(
        _ caseFile: inout BeholderPeople,
        _ person: UUID,
        _ username: String,
        _ provider: BeholderProvider,
        _ assessment: BeholderPeople.Assessment = .possible
    ) throws {
        try caseFile.link(
            personID: person,
            username: username,
            finding: finding(provider, username),
            assessment: assessment,
            reason: reason,
            evidence: assessment == .supported ? evidence : "",
            now: observed
        )
    }
}

private actor PeopleSearchSpy: BeholderSearching {
    private(set) var requests = 0
    func lookup(_ provider: BeholderProvider, username _: String) async -> BeholderFinding {
        requests += 1
        return BeholderFinding(provider: provider, status: .unavailable)
    }
}

@testable import Aegis
import Foundation
import XCTest

/// All payloads are invented; no external profile is requested.
final class BeholderSocialExpansionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let added: [BeholderProvider] = [
        .mastodonOnline, .mstdnSocial, .fosstodon, .hachyderm, .infosecExchange, .masTo, .socialVivaldi, .writeAs, .framaTube, .mixcloud,
    ]

    func testAddedAPIsStayOnTheirExactRoutes() throws {
        let hosts = [
            "mastodon.online",
            "mstdn.social",
            "fosstodon.org",
            "hachyderm.io",
            "infosec.exchange",
            "mas.to",
            "social.vivaldi.net",
            "write.as",
            "framatube.org",
            "api.mixcloud.com",
        ]
        for (provider, host) in zip(added, hosts) {
            let endpoint = try XCTUnwrap(provider.endpoint("ExampleAlex"))
            XCTAssertEqual(endpoint.host, host)
            XCTAssertEqual(endpoint.scheme, "https")
            XCTAssertTrue(BeholderProvider.permits(endpoint))
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(URL(string: endpoint.absoluteString + "?extra=1"))))
            var altered = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
            altered.port = 8443
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(altered.url)))
            altered.port = nil; altered.host = "example.com"
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(altered.url)))
            for invalid in ["Example/Alex", "Example%2FAlex", "examplealex@mastodon.social", "examplealex.bsky.social", "../example"] {
                XCTAssertNil(provider.endpoint(invalid))
            }
            XCTAssertEqual(provider.profileURL("ExampleAlex")?.host, provider == .mixcloud ? "www.mixcloud.com" : host)
        }
        XCTAssertEqual(BeholderProvider.writeAs.endpoint("ExampleAlex")?.path, "/api/collections/examplealex")
        XCTAssertEqual(BeholderProvider.framaTube.endpoint("ExampleAlex")?.path, "/api/v1/accounts/examplealex")
        XCTAssertNil(BeholderProvider.writeAs.endpoint("Example_Alex"))
        XCTAssertNil(BeholderProvider.framaTube.endpoint("Example-Alex"))
    }

    func testNamedMastodonServersRequireLocalAccountAndUsername() {
        for provider in added where provider.mastodonHost != nil {
            let result = parse(
                #"{"username":"ExampleAlex","acct":"examplealex","display_name":"Example Alex","url":"https://example.com/other"}"#,
                provider
            )
            XCTAssertEqual(result.status, .candidate)
            XCTAssertEqual(result.checkedAt, now)
            XCTAssertEqual(result.sourceURL, provider.endpoint("ExampleAlex"))
            XCTAssertEqual(result.fields["Display name"], "Example Alex")
            XCTAssertNil(result.fields["url"])
            for json in [
                #"{"username":"ExampleAlex","acct":"examplealex@example.com"}"#,
                #"{"username":"ExampleOther","acct":"examplealex"}"#,
                #"{"username":"ExampleAlex"}"#,
            ] {
                XCTAssertEqual(parse(json, provider).status, .unavailable)
            }
        }
    }

    func testWriteAsNeedsSuccessfulEnvelopeAndExactAlias() {
        let good = #"{"code":200,"data":{"alias":"examplealex","title":"Example blog","description":"<b>Example bio</b>","style_sheet":"ignored"}}"#
        let result = parse(good, .writeAs)
        XCTAssertEqual(result.status, .candidate)
        XCTAssertEqual(result.fields["Profile type"], "Blog")
        XCTAssertEqual(result.fields["Bio"], "Example bio")
        XCTAssertNil(result.fields["style_sheet"])
        for json in [
            good.replacingOccurrences(of: "200", with: "403"),
            good.replacingOccurrences(of: "examplealex", with: "exampleother"),
            #"{"alias":"examplealex"}"#,
            #"{"code":200,"data":[]}"#,
        ] {
            XCTAssertEqual(parse(json, .writeAs).status, .unavailable)
        }
    }

    func testPeerTubeNeedsTheExactLocalActor() {
        let good = #"{"name":"examplealex","host":"framatube.org","url":"https://framatube.org/accounts/examplealex","displayName":"Example Alex"}"#
        XCTAssertEqual(parse(good, .framaTube).status, .candidate)
        for json in [
            good.replacingOccurrences(of: "framatube.org", with: "example.com"),
            good.replacingOccurrences(of: "/accounts/examplealex", with: "/accounts/exampleother"),
            good.replacingOccurrences(of: "\"name\":\"examplealex\"", with: "\"name\":\"exampleother\""),
            good.replacingOccurrences(of: "https://framatube.org", with: "http://framatube.org"),
        ] {
            XCTAssertEqual(parse(json, .framaTube).status, .unavailable)
        }
    }

    func testSocialErrorsNeverBecomePositiveMatches() {
        for provider in added {
            for status in [200, 301, 400, 401, 403, 500] {
                XCTAssertEqual(parse(#"{"error":"Example unavailable"}"#, provider, status: status).status, .unavailable)
            }
            XCTAssertEqual(parse("", provider, status: 404).status, .noResult)
            XCTAssertEqual(parse("", provider, status: 429).status, .limited)
        }
    }

    func testMixcloudRequiresAnExactRootUserKey() {
        let good = #"{"key":"/ExampleAlex/","name":"Example Alex","biog":"Example bio"}"#
        XCTAssertEqual(parse(good, .mixcloud).status, .candidate)
        XCTAssertEqual(parse(good, .mixcloud).fields["Bio"], "Example bio")
        for json in [
            good.replacingOccurrences(of: "/ExampleAlex/", with: "/ExampleOther/"),
            good.replacingOccurrences(of: "/ExampleAlex/", with: "/ExampleAlex/example-show/"),
            #"{"key":"/ExampleAlex/","username":"ExampleOther"}"#,
            #"{"name":"ExampleAlex"}"#,
        ] {
            XCTAssertEqual(parse(json, .mixcloud).status, .unavailable)
        }
        for name in ["me", "search", "genres", "upload", "oauth"] {
            XCTAssertNil(BeholderProvider.mixcloud.endpoint(name))
        }
    }

    @MainActor func testManualOnlySearchMakesNoRequestsOrExistenceClaims() async {
        let transport = SocialCountingTransport()
        let client = BeholderClient(transport: transport)
        let model = BeholderModel(client: client)
        let manual = BeholderProvider.allCases.filter(\.isManual)
        XCTAssertGreaterThanOrEqual(manual.count, 40)
        XCTAssertEqual(Set(manual.map(\.rawValue)), Set(BeholderSocialDirectory.entries.map(\.id)).subtracting(["mixcloud"]))
        model.selected = Set(manual)
        model.query = "ExampleAlex"
        model.start()
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.findings.map(\.provider), manual)
        for finding in model.findings {
            XCTAssertTrue([.manual, .unsupported].contains(finding.status))
            XCTAssertNil(finding.checkedAt)
            XCTAssertNil(finding.sourceURL)
            XCTAssertNil(finding.provider.endpoint("ExampleAlex"))
            XCTAssertEqual(finding.provider.accessLabel, "Open manually")
            if let target = finding.preparedProfileURL {
                XCTAssertEqual(target.host, finding.provider.host)
                XCTAssertFalse(BeholderProvider.permits(target))
            }
            let direct = await client.lookup(finding.provider, username: "ExampleAlex")
            XCTAssertEqual(direct.status, finding.status)
            XCTAssertEqual(parse(#"{"username":"ExampleAlex"}"#, finding.provider).status, finding.status)
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.candidates, 0)
    }

    @MainActor func testMixedSearchCancellationPreservesUncheckedLinks() async throws {
        let transport = SocialCountingTransport()
        let model = BeholderModel(client: BeholderClient(transport: transport))
        model.selected = [.github, .instagram, .youtube]
        model.query = "ExampleAlex"
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await transport.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        model.cancel()
        XCTAssertEqual(model.findings.map(\.status), [.cancelled, .manual, .manual])
        XCTAssertFalse(model.searching)
        let count = await transport.requestCount
        XCTAssertEqual(count, 1)
        model.clear()
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(model.findings.isEmpty)
    }

    @MainActor func testExportDistinguishesPreparedLinksFromObservations() throws {
        let model = BeholderModel()
        model.selected = [.instagram]
        model.query = "ExampleAlex"
        model.start()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: model.export()) as? [String: Any])
        XCTAssertEqual(report["schema"] as? Int, 2)
        let finding = try XCTUnwrap((report["findings"] as? [[String: Any]])?.first)
        XCTAssertEqual(finding["status"] as? String, "manual")
        XCTAssertNotNil(finding["preparedProfileURL"])
        XCTAssertNil(finding["sourceURL"])
        XCTAssertNil(finding["checkedAt"])
        let old = Data(#"{"provider":"github","status":"candidate","fields":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(BeholderFinding.self, from: old).preparedProfileURL)
    }

    private func parse(_ json: String, _ provider: BeholderProvider, status: Int = 200) -> BeholderFinding {
        BeholderClient.parse(BeholderPayload(data: Data(json.utf8), status: status), provider: provider, username: "ExampleAlex", now: now)
    }
}

private actor SocialCountingTransport: BeholderTransport {
    private(set) var requestCount = 0
    func get(_: URL, accept _: String) async throws -> BeholderPayload {
        requestCount += 1
        try await Task.sleep(for: .milliseconds(200))
        return BeholderPayload(data: Data(#"{"login":"ExampleAlex"}"#.utf8), status: 200)
    }
}

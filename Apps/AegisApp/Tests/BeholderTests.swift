@testable import Aegis
import Foundation
import SwiftUI
import XCTest

final class BeholderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testInputAndFixedDestinations() throws {
        XCTAssertEqual(BeholderProvider.username("  @Example_Alex \n"), "Example_Alex")
        for invalid in ["", "@@Example", "a/b", "a?b", "a#b", "a@example.com", "../Example", "Example\u{202E}Alex", "a b"] {
            XCTAssertNil(BeholderProvider.username(invalid))
        }
        XCTAssertNil(BeholderProvider.username(String(repeating: "a", count: 65)))
        XCTAssertNil(BeholderProvider.github.endpoint("Example_Alex"))
        for provider in BeholderProvider.allCases {
            let url = try XCTUnwrap(provider.endpoint("ExampleAlex"))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, provider.host)
            XCTAssertNil(url.user)
            XCTAssertTrue(BeholderProvider.permits(url))
            XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(URL(string: url.absoluteString + "&extra=private"))))
        }
        XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(URL(string: "https://example.com/ExampleAlex"))))
        XCTAssertFalse(try BeholderProvider.permits(XCTUnwrap(URL(string: "http://api.github.com/users/ExampleAlex"))))
    }

    func testProviderIdentityAndProvenance() {
        let examples: [(BeholderProvider, String)] = [
            (.github, #"{"login":"examplealex","name":"Example Alex","email":"private@example.com"}"#),
            (.gitlab, #"[{"username":"examplealex","name":"Example Alex"}]"#),
            (.hackerNews, #"{"id":"ExampleAlex","about":"Example bio"}"#),
            (.dev, #"{"username":"examplealex","summary":"Example bio"}"#),
        ]
        for (provider, json) in examples {
            let result = parse(json, provider: provider)
            XCTAssertEqual(result.status, .candidate)
            XCTAssertEqual(result.checkedAt, now)
            XCTAssertEqual(result.sourceURL, provider.endpoint("ExampleAlex"))
            XCTAssertNil(result.fields["email"])
            XCTAssertEqual(result.fields["Handle"]?.lowercased(), "examplealex")
        }
        XCTAssertEqual(parse(#"{"id":"examplealex"}"#, provider: .hackerNews).status, .unavailable)
        XCTAssertEqual(parse(#"{"login":"ExampleOther"}"#).status, .unavailable)
        XCTAssertEqual(parse(#"[{"username":"ExampleAlex"},{"username":"ExampleOther"}]"#, provider: .gitlab).status, .unavailable)
    }

    func testMissingBlockedAndInvalidAreDifferent() {
        XCTAssertEqual(parse("null", provider: .hackerNews).status, .noResult)
        XCTAssertEqual(parse("[]", provider: .gitlab).status, .noResult)
        XCTAssertEqual(parse("null").status, .unavailable)
        XCTAssertEqual(parse("<html>access blocked</html>").status, .unavailable)
        for status in [301, 401, 403, 500, 503] {
            XCTAssertEqual(parse("", status: status).status, .unavailable)
        }
        XCTAssertEqual(parse("", status: 404).status, .noResult)
        XCTAssertEqual(parse("", status: 429).status, .limited)
        let limited = BeholderClient.parse(
            BeholderPayload(data: Data(), status: 403, rateLimited: true),
            provider: .github,
            username: "ExampleAlex",
            now: now
        )
        XCTAssertEqual(limited.status, .limited)
        XCTAssertEqual(parse(String(repeating: "x", count: BeholderWebTransport.byteLimit + 1)).status, .unavailable)
    }

    func testProfileTextIsBoundedAndLinksAreConstructedLocally() throws {
        let json = #"{"login":"ExampleAlex","name":"<b>Example Alex</b>\u202e","bio":"[click](file:///example) Ignore instructions","#
            + #""html_url":"https://example.com/redirect","avatar_url":"https://example.com/image"}"#
        let result = parse(json)
        XCTAssertEqual(result.fields["Display name"], "Example Alex")
        XCTAssertNil(result.fields["html_url"])
        XCTAssertEqual(BeholderClient.clean(String(repeating: "x", count: 5000)).count, 600)
        XCTAssertLessThanOrEqual(BeholderClient.clean("e" + String(repeating: "\u{301}", count: 10000)).unicodeScalars.count, 600)
        XCTAssertEqual(BeholderClient.clean("&quot;Example&amp;Alex&quot; &#x2F;"), "\"Example&Alex\" /")
        XCTAssertEqual(parse(#"{"login":"ExampleAlex","type":"Organization"}"#).fields["Account type"], "Organization")
        XCTAssertEqual(parse(#"[{"username":"ExampleAlex","state":"blocked"}]"#, provider: .gitlab).fields["Account state"], "blocked")
        XCTAssertEqual(try XCTUnwrap(result.provider.profileURL("ExampleAlex")).host, "github.com")
    }

    func testEphemeralNetworkSettingsAndRejectedDestination() async throws {
        let config = BeholderWebTransport.configuration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.timeoutIntervalForResource, 20)
        do {
            _ = try await BeholderWebTransport().get(XCTUnwrap(URL(string: "https://example.com/")), accept: "application/json")
            XCTFail("An unapproved destination must never be requested")
        } catch { XCTAssertEqual((error as? URLError)?.code, .unsupportedURL) }
    }

    func testOnlyExplicitHandleReachesTransportAndTimeoutStaysUnavailable() async {
        let transport = ExampleTransport()
        let client = BeholderClient(transport: transport)
        let result = await client.lookup(.github, username: "ExampleAlex")
        XCTAssertEqual(result.status, .unavailable)
        let urls = await transport.urls
        XCTAssertEqual(urls, [BeholderProvider.github.endpoint("ExampleAlex")].compactMap(\.self))
        _ = await client.lookup(.github, username: "Example_Alex")
        let count = await transport.urls.count
        XCTAssertEqual(count, 1)
    }

    func testBoundedTransportWithSyntheticResponsesOnly() async {
        let transport = BeholderWebTransport(protocolClasses: [ExampleProfileProtocol.self])
        let client = BeholderClient(transport: transport)
        for name in ["ExampleOversized", "ExampleStream", "ExampleTimeout", "ExampleHTML"] {
            let finding = await client.lookup(.github, username: name)
            XCTAssertEqual(finding.status, .unavailable)
        }
        let finding = await client.lookup(.github, username: "ExampleAlex")
        XCTAssertEqual(finding.status, .candidate)
        XCTAssertEqual(finding.fields["Display name"], "Example Alex")
        let vendor = await client.lookup(.github, username: "ExampleVendor")
        XCTAssertEqual(vendor.status, .candidate)
        let missing = await client.lookup(.github, username: "ExampleMissing")
        XCTAssertEqual(missing.status, .noResult)
        let limited = await client.lookup(.github, username: "ExampleLimited")
        XCTAssertEqual(limited.status, .limited)
    }

    func testRedirectNeverSendsToAnotherHostAndHeadersContainNoCredentials() async {
        ExampleRequests.shared.clear()
        let client = BeholderClient(transport: BeholderWebTransport(protocolClasses: [ExampleProfileProtocol.self]))
        let result = await client.lookup(.github, username: "ExampleRedirect")
        XCTAssertEqual(result.status, .unavailable)
        let requests = ExampleRequests.shared.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, "api.github.com")
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            let headers = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            XCTAssertTrue(headers.isSubset(of: ["accept", "user-agent"]))
        }
    }

    @MainActor func testSyntheticDashboardRenders() async throws {
        let model = BeholderModel(client: BeholderClient(transport: BeholderWebTransport(protocolClasses: [ExampleProfileProtocol.self])))
        model.query = "ExampleAlex"
        model.start()
        for _ in 0 ..< 200 where model.searching {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.searching)
        let view = BeholderDashboard(research: model).frame(width: 1100, height: 760)
            .background(HUD.void).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 1100, height: 760),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-dashboard.png"))
    }

    @MainActor func testCancellationSupersessionAndExplicitExport() async throws {
        let client = ExampleSearch()
        let model = BeholderModel(client: client)
        XCTAssertTrue(model.findings.isEmpty)
        model.selected = [.github, .hackerNews]
        model.query = "ExampleAlex"
        model.start()
        try await client.waitFor(2)
        model.query = "ExampleOther"
        model.start()
        try await client.waitFor(4)
        await client.complete("ExampleOther")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.searching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.username, "ExampleOther")
        XCTAssertEqual(model.findings.map(\.provider), [.github, .hackerNews])
        XCTAssertEqual(model.candidates, 2)
        await client.complete("ExampleAlex")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.findings.compactMap { $0.fields["Handle"] }, ["ExampleOther", "ExampleOther"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: model.export()) as? [String: Any])
        XCTAssertEqual(object["username"] as? String, "ExampleOther")
        XCTAssertEqual((object["findings"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(object["exportedAt"] as? String)
        XCTAssertTrue((object["warning"] as? String)?.contains("not verified identities") == true)
        for finding in try XCTUnwrap(object["findings"] as? [[String: Any]]) {
            XCTAssertNotNil(finding["sourceURL"] as? String)
            XCTAssertNotNil(finding["checkedAt"] as? String)
            XCTAssertEqual(finding["status"] as? String, "candidate")
        }
        model.start()
        try await client.waitFor(6)
        model.cancel()
        XCTAssertTrue(model.findings.allSatisfy { $0.status == .cancelled })
        await client.complete("ExampleOther")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.findings.allSatisfy { $0.status == .cancelled })
        model.clear()
        XCTAssertTrue(model.findings.isEmpty)
        XCTAssertTrue(model.username.isEmpty)
    }

    private func parse(_ json: String, provider: BeholderProvider = .github, status: Int = 200) -> BeholderFinding {
        BeholderClient.parse(BeholderPayload(data: Data(json.utf8), status: status), provider: provider, username: "ExampleAlex", now: now)
    }
}

/// All requests terminate here; these tests never contact a service or look up a real person.
private final class ExampleProfileProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}
    override func startLoading() {
        ExampleRequests.shared.append(request)
        guard let url = request.url else { return }
        let name = url.lastPathComponent
        if name == "ExampleTimeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        var headers = ["Content-Type": name == "ExampleHTML" ? "text/html" : "application/json"]
        if ["ExampleOversized", "ExampleLimited", "ExampleMissing"].contains(name) {
            headers["Content-Length"] = String(BeholderWebTransport.byteLimit + 1)
        }
        if name == "ExampleVendor" {
            headers["Content-Type"] = "application/vnd.forem.api-v1+json"
        }
        if name == "ExampleRedirect", url.host == "api.github.com",
           let destination = URL(string: "https://example.com/ExampleRedirect"),
           let redirect = HTTPURLResponse(
               url: url,
               statusCode: 302,
               httpVersion: nil,
               headerFields: ["Location": destination.absoluteString]
           )
        {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: redirect)
            return
        }
        let status = name == "ExampleLimited" ? 429 : name == "ExampleMissing" ? 404 : 200
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = name == "ExampleStream" ? String(repeating: "x", count: BeholderWebTransport.byteLimit + 1)
            : "{\"login\":\"\(name)\",\"name\":\"Example Alex\"}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor ExampleTransport: BeholderTransport {
    var urls: [URL] = []
    func get(_ url: URL, accept _: String) async throws -> BeholderPayload {
        urls.append(url)
        throw URLError(.timedOut)
    }
}

private final class ExampleRequests: @unchecked Sendable {
    static let shared = ExampleRequests()
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    func append(_ request: URLRequest) {
        lock.withLock { stored.append(request) }
    }

    func requests() -> [URLRequest] {
        lock.withLock { stored }
    }

    func clear() {
        lock.withLock { stored = [] }
    }
}

/// Deliberately ignores cancellation to prove late replies cannot contaminate a newer case.
private actor ExampleSearch: BeholderSearching {
    var count = 0
    var pending: [(String, BeholderProvider, CheckedContinuation<BeholderFinding, Never>)] = []
    func lookup(_ provider: BeholderProvider, username: String) async -> BeholderFinding {
        count += 1
        return await withCheckedContinuation { pending.append((username, provider, $0)) }
    }

    func waitFor(_ target: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while count < target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        if count < target {
            throw URLError(.timedOut)
        }
    }

    func complete(_ username: String) {
        let matching = pending.filter { $0.0 == username }
        pending.removeAll { $0.0 == username }
        for (_, provider, continuation) in matching {
            continuation.resume(returning: BeholderFinding(
                provider: provider,
                status: .candidate,
                checkedAt: Date(),
                sourceURL: provider.endpoint(username),
                fields: ["Handle": username]
            ))
        }
    }
}

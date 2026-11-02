@testable import Aegis
import XCTest

final class BeholderGitHubTransportTests: XCTestCase {
    func testDiscoveryEndpointRequiresAnOptedInTransportAndUsesNoCredentials() async throws {
        DiscoveryURLProtocol.ledger.clear()
        let request = try XCTUnwrap(BeholderGitHubDiscovery.prepare(.init(value: "Example Alex", kind: .name)))
        let ordinary = BeholderWebTransport(protocolClasses: [DiscoveryURLProtocol.self])
        do {
            _ = try await ordinary.get(request.endpoint, accept: "application/json")
            XCTFail("Default username transport must reject this endpoint")
        } catch { XCTAssertEqual((error as? URLError)?.code, .unsupportedURL) }
        XCTAssertTrue(DiscoveryURLProtocol.ledger.requests.isEmpty)
        let permitted = BeholderWebTransport(protocolClasses: [DiscoveryURLProtocol.self], permitsGitHubDiscovery: true)
        let result = await BeholderGitHubDiscoveryClient(transport: permitted).search(request)
        XCTAssertEqual(try result.get().hits.count, 0)
        let recorded = try XCTUnwrap(DiscoveryURLProtocol.ledger.requests.first)
        XCTAssertEqual(recorded.url, request.endpoint); XCTAssertEqual(recorded.httpMethod, "GET")
        XCTAssertNil(recorded.httpBody); XCTAssertNil(recorded.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(recorded.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(DiscoveryURLProtocol.ledger.requests.count, 1)
    }
}

private final class DiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    static let ledger = DiscoveryRequestLedger()
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}
    override func startLoading() {
        Self.ledger.append(request)
        guard let url = request.url, let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DiscoveryRequestLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    var requests: [URLRequest] {
        lock.withLock { values }
    }

    func clear() {
        lock.withLock { values = [] }
    }

    func append(_ request: URLRequest) {
        lock.withLock { values.append(request) }
    }
}

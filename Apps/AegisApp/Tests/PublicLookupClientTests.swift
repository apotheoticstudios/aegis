@testable import Aegis
import AegisKit
import Foundation
import XCTest

final class PublicLookupClientTests: XCTestCase {
    func testSearchRequestIsOnlyAnAnonymousGETToTheFixedProvider() throws {
        let plan = PublicLookupPlan(id: UUID(), query: "astronomy & physics", expiresAt: Date().addingTimeInterval(60))
        let request = try PublicLookupClient.request(plan)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "www.bing.com")
        XCTAssertEqual(request.url?.path, "/search")
        let items = try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.first(where: { $0.name == "q" })?.value, plan.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertThrowsError(try PublicLookupClient.request(.init(id: UUID(), query: "astronomy", expiresAt: .distantPast)))
    }

    func testRedirectPolicyNeverFollowsAResultLinkOrAnotherHost() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        let task = session.dataTask(with: url) // never resumed; synthetic delegate invocation only
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/next"]
        ))
        let called = expectation(description: "Redirect is refused")
        PublicLookupNetworkPolicy()
            .urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { request in
                XCTAssertNil(request)
                called.fulfill()
            }
        wait(for: [called], timeout: 1)
    }

    func testRSSReadsOnlyPlainTitlesAndExcerptsNeverFollowsLinks() throws {
        let xml = #"<rss><channel><title>Ignored</title><item><title>Example Observatory</title>"#
            + #"<link>https://example.com/upload</link><description>Stars &lt;b&gt;emit&lt;/b&gt; light.</description></item></channel></rss>"#
        let sources = try PublicLookupClient.parse(Data(xml.utf8))
        XCTAssertEqual(sources, [.init(title: "Example Observatory", excerpt: "Stars emit light.")])
    }

    func testRejectsExternalEntitiesOversizeHTMLAndMalformedDocuments() {
        for xml in [
            #"<!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///example/private">]><rss/>"#,
            "<html>not a search feed</html>",
            "<rss><item>",
        ] {
            XCTAssertThrowsError(try PublicLookupClient.parse(Data(xml.utf8)))
        }
        XCTAssertThrowsError(try PublicLookupClient.parse(Data(repeating: 0, count: PublicLookupClient.maximumBytes + 1)))
    }

    func testReturnedPageLinksCannotAppearInSourceNamesAndSourcesAreBounded() throws {
        let xml = "<rss><channel>" + (0 ..< 8).map { index in
            "<item><title>Example \(index) https://example.com/</title><description>" + String(repeating: "a", count: 1600) + "</description></item>"
        }.joined() + "</channel></rss>"
        let sources = try PublicLookupClient.parse(Data(xml.utf8))
        XCTAssertEqual(sources.count, 5)
        XCTAssertTrue(sources.allSatisfy { !$0.title.contains("https://") && $0.excerpt.count == 1200 })
    }
}

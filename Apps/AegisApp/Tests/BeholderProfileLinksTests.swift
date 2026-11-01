@testable import Aegis
import XCTest

/// Invented example.com-style addresses only: nothing is fetched or resolved.
final class BeholderProfileLinksTests: XCTestCase {
    private typealias Links = BeholderProfileLinks

    private func canonical(_ input: String) -> String? {
        Links.canonical(input)?.absoluteString
    }

    func testOnlySchemeHostDefaultPortAndFragmentChange() {
        XCTAssertEqual(canonical("HTTPS://Example.COM:443/Alice?Tab=Repos#About"), "https://example.com/Alice?Tab=Repos")
        XCTAssertEqual(canonical("  https://example.com/@ExampleAlex  "), "https://example.com/@ExampleAlex")
        XCTAssertEqual(canonical("https://xn--exmple-cua.example/Alice"), "https://xn--exmple-cua.example/Alice")
        XCTAssertEqual(canonical("https://example.com"), "https://example.com")
        XCTAssertEqual(canonical("https://example.com/a%2Fb?q=x%26y&r=1"), "https://example.com/a%2Fb?q=x%26y&r=1")
    }

    func testSpellingSlashesWwwAndQueriesStayDistinct() {
        let distinct = [
            "https://example.com/alice", "https://example.com/Alice", "https://example.com/alice/", "https://www.example.com/alice",
            "https://example.com/alice?a=1&b=2", "https://example.com/alice?b=2&a=1", "https://example.com/alice?",
            "https://example.com/a%2Fb", "https://example.com/a%2fb", "https://example.com/a/b", "https://example.com",
            "https://example.com/", "https://example.com//alice",
        ]
        let results = distinct.compactMap(canonical)
        XCTAssertEqual(results.count, distinct.count, "All are valid")
        XCTAssertEqual(Set(results).count, distinct.count, "No aliasing, slash collapsing or query dropping")
    }

    func testRejectsUnsafeOrNonPublicAddresses() {
        let rejected = [
            "", "   ", "example.com/alice", "/alice", "//example.com/alice", "http://example.com/alice", "ftp://example.com/alice",
            "javascript:alert(1)", "https://user@example.com/alice", "https://user:secret@example.com/alice",
            "https://example.com@evil.example/alice", "https://example.com:8443/alice", "https://example.com:80/alice",
            "https://127.0.0.1/alice", "https://[::1]/alice", "https://10.0.0.1/alice", "https://localhost/alice",
            "https://printer.local/alice", "https://router.home.arpa/alice", "https://wiki.corp/alice", "https://example.internal/a",
            "https://example.com./alice", "https://example/alice", "https://-example.com/alice", "https://exa%6Dple.com/alice",
            "https://exämple.com/alice", "https://example.com/älice", "https://example.com/a b", "https://example.com/a\\b",
            "https://example.com/\u{202E}ecila", "https://example.com/a\u{0}b", "https://example.com/a%00b", "https://example.com/a%0Ab",
            "https://example.com/a%E2%80%AEb", "https://example.com/a%zz", "https://example.com/a%4", "https://example.com/a%C3%28",
            "https://example.com/alice?x=%0D", "https://example.com/a/../bob", "https://example.com/./alice",
            "https://example.com/%2e%2E/bob", "https://example.com/<alice>", "https://example.com/" + String(repeating: "a", count: 2048),
        ]
        for input in rejected {
            XCTAssertNil(Links.canonical(input), input)
        }
        XCTAssertNotNil(Links.canonical("https://example.com/" + String(repeating: "a", count: 2000)))
    }

    func testRelationUsesExactHostLabelsAndKnownProfileAddresses() {
        let exact = [
            "https://github.com/ExampleAlex", "HTTPS://GitHub.com/ExampleAlex#readme", "https://github.com:443/ExampleAlex",
        ]
        for link in exact {
            XCTAssertEqual(Links.relation(link, provider: .github, username: "ExampleAlex"), .exact, link)
        }
        let different = [
            "https://github.com/examplealex", "https://github.com/ExampleAlex/", "https://www.github.com/ExampleAlex",
            "https://github.com.evil.example/ExampleAlex", "https://evilgithub.com/ExampleAlex", "https://gist.github.com/ExampleAlex",
            "https://github.com/ExampleAlex?tab=repositories", "https://github.com/ExampleAlexander", "https://example.com/ExampleAlex",
        ]
        for link in different {
            XCTAssertEqual(Links.relation(link, provider: .github, username: "ExampleAlex"), .different, link)
        }
        XCTAssertEqual(
            Links.relation("https://github.com@evil.example/ExampleAlex", provider: .github, username: "ExampleAlex"),
            .unsupported
        )
        XCTAssertEqual(Links.relation("http://github.com/ExampleAlex", provider: .github, username: "ExampleAlex"), .unsupported)
        XCTAssertEqual(Links.relation("https://github.com/Example_Alex", provider: .github, username: "Example_Alex"), .unsupported)
        XCTAssertEqual(Links.relation("https://www.instagram.com/ExampleAlex/", provider: .instagram, username: "ExampleAlex"), .exact)
        XCTAssertEqual(Links.relation("https://instagram.com/ExampleAlex/", provider: .instagram, username: "ExampleAlex"), .different)
        XCTAssertEqual(Links.relation("https://mastodon.social/@examplealex", provider: .mastodon, username: "ExampleAlex"), .exact)
    }

    func testRawBoundAndHiddenCharactersApplyBeforeTrimming() {
        let link = "https://example.com/alice"
        XCTAssertEqual(canonical("   " + link + "   "), link, "Ordinary spaces are trimmed")
        for wrapped in [
            link + "\n", "\n" + link, "\r\n" + link + "\r\n", "\t" + link, link + "\t", "\u{200B}" + link, link + "\u{FEFF}",
            "\u{202E}" + link, "\u{2028}" + link, "\u{00A0}" + link,
        ] {
            XCTAssertNil(Links.canonical(wrapped), wrapped.debugDescription)
        }
        let padding = String(repeating: " ", count: Links.maxLength)
        XCTAssertNil(Links.canonical(padding + link), "Padding counts towards the raw byte bound")
        XCTAssertNil(Links.canonical(link + padding))
        let atLimit = String(repeating: " ", count: Links.maxLength - link.utf8.count) + link
        XCTAssertEqual(canonical(atLimit), link)
        XCTAssertTrue(Links.deduplicate([(link: padding + link, source: "owner")]).isEmpty)
    }

    func testDeduplicationSkipsUnboundedOrHiddenSourceLabels() {
        let link = "https://example.com/alice"
        let bad = ["", String(repeating: "s", count: Links.maxSourceLength + 1), "owner\n", "own\u{202E}er"]
        XCTAssertTrue(Links.deduplicate(bad.map { (link: link, source: $0) }).isEmpty)
        let kept = Links.deduplicate([
            (link: link, source: "owner\n"),
            (link: link, source: String(repeating: "s", count: Links.maxSourceLength)),
        ])
        XCTAssertEqual(kept.map(\.source), [String(repeating: "s", count: Links.maxSourceLength)], "A rejected label never claims the link")
    }

    func testDeduplicationIsBoundedDeterministicAndKeepsFirstProvenance() {
        let input: [(link: String, source: String)] = [
            ("https://Example.com/Alice#bio", "github"), ("not a link", "owner"), ("https://example.com/Alice", "gitlab"),
            ("https://example.com/alice", "dev"), ("https://EXAMPLE.com:443/Alice?", "owner"), ("https://example.com/Alice#x", "owner"),
        ]
        let entries = Links.deduplicate(input)
        XCTAssertEqual(entries.map(\.canonical.absoluteString), [
            "https://example.com/Alice", "https://example.com/alice", "https://example.com/Alice?",
        ])
        XCTAssertEqual(
            entries.map(\.original),
            ["https://Example.com/Alice#bio", "https://example.com/alice", "https://EXAMPLE.com:443/Alice?"]
        )
        XCTAssertEqual(entries.map(\.source), ["github", "dev", "owner"])
        XCTAssertEqual(entries, Links.deduplicate(input))
        let many = (0 ..< Links.maxEntries + 100).map { (link: "https://example.com/user\($0)", source: "owner") }
        let bounded = Links.deduplicate(many)
        XCTAssertEqual(bounded.count, Links.maxEntries)
        XCTAssertEqual(bounded.last?.original, "https://example.com/user\(Links.maxEntries - 1)")
    }
}

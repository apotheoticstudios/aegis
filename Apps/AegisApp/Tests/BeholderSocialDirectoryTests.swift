@testable import Aegis
import XCTest

/// Pure URL building with synthetic Example handles: nothing is fetched or opened.
final class BeholderSocialDirectoryTests: XCTestCase {
    private let entries = BeholderSocialDirectory.entries

    /// Frozen: Codex mirrors these as `BeholderProvider` cases, so order and spelling must not drift.
    private let expected: KeyValuePairs<String, String> = [
        "instagram": "https://www.instagram.com/ExampleAlex/",
        "x": "https://x.com/ExampleAlex",
        "tiktok": "https://www.tiktok.com/@ExampleAlex",
        "threads": "https://www.threads.com/@ExampleAlex",
        "youtube": "https://www.youtube.com/@ExampleAlex",
        "linkedIn": "https://www.linkedin.com/in/ExampleAlex",
        "pinterest": "https://www.pinterest.com/ExampleAlex/",
        "snapchat": "https://www.snapchat.com/add/ExampleAlex",
        "twitch": "https://www.twitch.tv/ExampleAlex",
        "reddit": "https://www.reddit.com/user/ExampleAlex",
        "tumblr": "https://tumblr.com/ExampleAlex",
        "telegram": "https://t.me/ExampleAlex",
        "medium": "https://medium.com/@ExampleAlex",
        "soundCloud": "https://soundcloud.com/ExampleAlex",
        "bandcamp": "https://bandcamp.com/ExampleAlex",
        "steam": "https://steamcommunity.com/id/ExampleAlex/",
        "deviantArt": "https://www.deviantart.com/ExampleAlex",
        "behance": "https://www.behance.net/ExampleAlex",
        "dribbble": "https://dribbble.com/ExampleAlex",
        "artStation": "https://www.artstation.com/ExampleAlex",
        "flickr": "https://www.flickr.com/people/ExampleAlex",
        "vsco": "https://vsco.co/ExampleAlex",
        "letterboxd": "https://letterboxd.com/ExampleAlex/",
        "lastFm": "https://www.last.fm/user/ExampleAlex",
        "goodreads": "https://www.goodreads.com/ExampleAlex",
        "wattpad": "https://www.wattpad.com/user/ExampleAlex",
        "strava": "https://www.strava.com/athletes/ExampleAlex",
        "patreon": "https://www.patreon.com/ExampleAlex",
        "koFi": "https://ko-fi.com/ExampleAlex",
        "buyMeACoffee": "https://buymeacoffee.com/ExampleAlex",
        "aboutMe": "https://about.me/ExampleAlex",
        "substack": "https://substack.com/@ExampleAlex",
        "kick": "https://kick.com/ExampleAlex",
        "rumble": "https://rumble.com/user/ExampleAlex",
        "minds": "https://www.minds.com/ExampleAlex/",
        "vk": "https://vk.com/ExampleAlex",
        "vimeo": "https://vimeo.com/ExampleAlex",
        "dailymotion": "https://www.dailymotion.com/ExampleAlex",
        "linktree": "https://linktr.ee/ExampleAlex",
        "imgur": "https://imgur.com/user/ExampleAlex",
        "discogs": "https://www.discogs.com/user/ExampleAlex",
        "trakt": "https://www.trakt.tv/users/ExampleAlex",
        "duolingo": "https://www.duolingo.com/profile/ExampleAlex",
        "unsplash": "https://unsplash.com/@examplealex",
        "untappd": "https://untappd.com/user/ExampleAlex",
        "codePen": "https://codepen.io/ExampleAlex",
        "productHunt": "https://www.producthunt.com/@ExampleAlex",
        "myspace": "https://myspace.com/ExampleAlex",
        "spotify": "https://open.spotify.com/user/ExampleAlex",
        "genius": "https://genius.com/ExampleAlex",
    ]

    func testIDsAreFrozenUniqueSwiftNamesClearOfExistingSources() {
        let ids = entries.map(\.id)
        XCTAssertEqual(ids, expected.map(\.key))
        XCTAssertGreaterThanOrEqual(ids.count, 40)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(entries.map(\.host)).count, ids.count, "One directory entry per site")
        // The original twelve, fixed: Codex adds these IDs as provider cases on integration.
        let existing: Set = [
            "github", "gitlab", "hackerNews", "dev", "codeberg", "dockerHub",
            "keybase", "lichess", "chess", "scratch", "bluesky", "mastodon",
        ]
        for id in ids {
            XCTAssertNotNil(id.range(of: #"\A[a-z][A-Za-z0-9]*\z"#, options: .regularExpression), id)
            XCTAssertFalse(existing.contains(id), id)
            XCTAssertEqual(BeholderSocialDirectory.entry(id: id)?.id, id)
        }
        XCTAssertNil(BeholderSocialDirectory.entry(id: "github"))
        XCTAssertNil(BeholderSocialDirectory.entry(id: "Instagram"))
    }

    func testValidExampleBuildsFixedHTTPSHostAndPath() throws {
        for (id, url) in expected {
            let entry = try XCTUnwrap(BeholderSocialDirectory.entry(id: id))
            let handle = id == "unsplash" ? "examplealex" : "ExampleAlex"
            let built = try XCTUnwrap(entry.profileURL(handle), id)
            XCTAssertEqual(built.absoluteString, url)
            XCTAssertEqual(built.scheme, "https")
            XCTAssertEqual(built.host, entry.host)
            XCTAssertNil(built.query)
            XCTAssertNil(built.fragment)
        }
    }

    func testPerSiteRulesRejectUnsupportedHandles() throws {
        let cases: [(String, String)] = [
            ("x", "ExampleAlexTooLong"), ("vimeo", "12345"), ("unsplash", "ExampleAlex"),
            ("telegram", "Ex_1"), ("telegram", "_ExampleAlex"),
            ("snapchat", "ExampleAlex_"), ("linkedIn", "Example_Alex"), ("buyMeACoffee", "Example_Alex"),
            ("twitch", "Exa"), ("substack", "Exa"), ("substack", "Example_Alex"), ("tumblr", "Example_Alex"),
            ("deviantArt", "1ExampleAlex"),
            (
                "lastFm",
                "ExampleAlexTooLong"
            ),
        ]
        for (id, handle) in cases {
            XCTAssertNil(try XCTUnwrap(BeholderSocialDirectory.entry(id: id)).profileURL(handle), "\(id) \(handle)")
        }
    }

    func testInjectionAndQualifiedBlueskyRejectedEverywhere() {
        let hostile = [
            "", ".", "..", ".ExampleAlex", "Example..Alex", "Example/Alex", "../ExampleAlex", "Example?x=1",
            "Example#x", "Example%2FAlex", "Example&x", "https://evil.example/ExampleAlex", "evil.example:443",
            "example@example.com", "@ExampleAlex", " ExampleAlex", "ExampleAlex\n", "Example\u{0}Alex",
            "Example\u{200B}Alex", "Ex\u{E4}mple", "Ｅxample", "Example Alex",
            "examplealex.bsky.social", "ExampleAlex.BSKY.SOCIAL",
        ]
        for entry in entries {
            for input in hostile {
                XCTAssertNil(entry.profileURL(input), "\(entry.id) accepted \(input.debugDescription)")
            }
        }
    }

    func testDirectoryIsFoundationOnlyWithoutNetworking() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Beholder/BeholderSocialDirectory.swift"),
            encoding: .utf8
        )
        let imports = source.split(separator: "\n").filter { $0.hasPrefix("import ") }
        XCTAssertEqual(imports, ["import Foundation"])
        for banned in ["URLSession", "URLRequest", "NSWorkspace", "dataTask", "open("] {
            XCTAssertFalse(source.contains(banned), banned)
        }
        XCTAssertTrue(entries.allSatisfy { !$0.reason.isEmpty && !$0.title.isEmpty })
    }
}

import Foundation

/// Selected Sherlock discovery ideas, verified against public API schemas; no remote catalogue or executable dependency.
extension BeholderProvider {
    static func blueskyBase(_ actor: String?) -> String? {
        let suffix = ".bsky.social"
        guard let actor, actor.hasSuffix(suffix) else { return nil }
        return String(actor.dropLast(suffix.count))
    }

    /// Bluesky is explicitly limited to its named namespace, not arbitrary federation hosts or guessed identifiers.
    func lookupHandle(_ username: String) -> String {
        let lower = username.lowercased()
        if self == .bluesky {
            return lower.hasSuffix(".bsky.social") ? lower : lower + ".bsky.social"
        }
        return self == .hackerNews ? username : lower
    }

    func matchesExpandedSyntax(_ username: String) -> Bool {
        if self == .codeberg, username.lowercased() == "search" {
            return false
        }
        let pattern: String
        switch self {
        case .codeberg: pattern = #"[A-Za-z0-9][A-Za-z0-9_.-]{0,39}"#
        case .dockerHub: pattern = #"[A-Za-z0-9]{2,30}"#
        case .keybase: pattern = #"[A-Za-z][A-Za-z0-9_]{1,15}"#
        case .lichess: pattern = #"[A-Za-z0-9_-]{2,20}"#
        case .chess: pattern = #"[A-Za-z0-9_-]{3,25}"#
        case .scratch: pattern = #"[A-Za-z0-9_-]{3,20}"#
        case .bluesky: pattern = #"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.bsky\.social)?"#
        case .mastodon: pattern = #"[A-Za-z0-9_]{1,30}"#
        default: return false
        }
        return username.range(of: "\\A(?:" + pattern + ")\\z", options: [.regularExpression, .caseInsensitive]) != nil
    }

    func expandedEndpoint(_ username: String) -> URL? {
        let handle = lookupHandle(username)
        switch self {
        case .codeberg: return Self.address(host, "/api/v1/users/" + handle)
        case .dockerHub: return Self.address(host, "/v2/users/" + handle + "/")
        case .keybase: return Self.address(host, "/_/api/1.0/user/lookup.json", [("usernames", handle), ("fields", "basics,profile")])
        case .lichess: return Self.address(host, "/api/user/" + handle)
        case .chess: return Self.address(host, "/pub/player/" + handle)
        case .scratch: return Self.address(host, "/users/" + handle)
        case .bluesky: return Self.address(host, "/xrpc/app.bsky.actor.getProfile", [("actor", handle)])
        case .mastodon: return Self.address(host, "/api/v1/accounts/lookup", [("acct", handle)])
        default: return nil
        }
    }

    func expandedProfileURL(_ username: String) -> URL? {
        let handle = lookupHandle(username)
        switch self {
        case .codeberg, .keybase: return Self.address(host, "/" + handle)
        case .dockerHub: return Self.address(host, "/u/" + handle)
        case .lichess: return Self.address(host, "/@/" + handle)
        case .chess: return Self.address("www.chess.com", "/member/" + handle)
        case .scratch: return Self.address("scratch.mit.edu", "/users/" + handle + "/")
        case .bluesky: return Self.address("bsky.app", "/profile/" + handle)
        case .mastodon: return Self.address(host, "/@" + handle)
        default: return nil
        }
    }

    private static func address(_ host: String, _ path: String, _ query: [(String, String)] = []) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        if !query.isEmpty {
            parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return parts.url
    }
}

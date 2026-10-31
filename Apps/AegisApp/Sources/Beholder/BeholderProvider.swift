import Foundation

/// App-private discovery rules. A profile with the same handle is a candidate, never an identified person.
enum BeholderProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case github, gitlab, hackerNews, dev
    case codeberg, dockerHub, keybase, lichess, chess, scratch, bluesky, mastodon
    case mastodonOnline, mstdnSocial, fosstodon, hachyderm, infosecExchange, masTo, socialVivaldi, writeAs, framaTube, mixcloud

    case instagram
    case twitter = "x"
    case tiktok, threads, youtube, linkedIn
    case pinterest, snapchat, twitch, reddit, tumblr, telegram, medium
    case soundCloud, bandcamp, steam, deviantArt, behance, dribbble, artStation
    case flickr, vsco, letterboxd, lastFm, goodreads, wattpad, strava
    case patreon, koFi, buyMeACoffee, aboutMe, substack, kick, rumble
    case minds, vk, vimeo, dailymotion, linktree, imgur, discogs
    case trakt, duolingo, unsplash, untappd, codePen, productHunt, myspace
    case spotify, genius

    static var automaticSources: [Self] {
        allCases.filter { !$0.isManual }
    }

    var manualEntry: BeholderSocialEntry? {
        guard socialAPIHost == nil else { return nil }
        return Self.manualEntriesByID[rawValue]
    }

    private static let manualEntriesByID = Dictionary(uniqueKeysWithValues: BeholderSocialDirectory.entries.map { ($0.id, $0) })

    var isManual: Bool {
        manualEntry != nil
    }

    var accessLabel: String {
        isManual ? "Open manually" : "Automatic check"
    }

    func manualFinding(_ username: String) -> BeholderFinding? {
        guard let entry = manualEntry else { return nil }
        let target = entry.profileURL(username)
        var finding = BeholderFinding(provider: self, status: target == nil ? .unsupported : .manual)
        finding.preparedProfileURL = target
        finding.fields["Access"] = entry.reason
        return finding
    }

    /// Expansion never silently adds destinations to an existing owner's search.
    static var originalSources: Set<Self> {
        Set(allCases.prefix(4))
    }

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .hackerNews: "Hacker News"
        case .dev: "DEV"
        case .codeberg: "Codeberg"
        case .dockerHub: "Docker Hub"
        case .keybase: "Keybase"
        case .lichess: "Lichess"
        case .chess: "Chess.com"
        case .scratch: "Scratch"
        case .bluesky: "Bluesky (.bsky.social)"
        case .mastodon: "Mastodon.social"
        default: manualEntry?.title ?? socialAPITitle ?? rawValue
        }
    }

    var host: String {
        switch self {
        case .github: "api.github.com"
        case .gitlab: "gitlab.com"
        case .hackerNews: "hacker-news.firebaseio.com"
        case .dev: "dev.to"
        case .codeberg: "codeberg.org"
        case .dockerHub: "hub.docker.com"
        case .keybase: "keybase.io"
        case .lichess: "lichess.org"
        case .chess: "api.chess.com"
        case .scratch: "api.scratch.mit.edu"
        case .bluesky: "public.api.bsky.app"
        case .mastodon: "mastodon.social"
        default: manualEntry?.host ?? socialAPIHost ?? ""
        }
    }

    /// Deliberately accepts handles only: no URLs, email addresses, paths, query strings or hidden controls.
    static func username(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        guard value.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z"#, options: .regularExpression) != nil,
              !value.contains("..") else { return nil }
        return value
    }

    func supports(_ username: String) -> Bool {
        if let manualEntry {
            return manualEntry.profileURL(username) != nil
        }
        if self != .bluesky, username.lowercased().hasSuffix(".bsky.social") {
            return false
        }
        return switch self {
        case .github:
            username.count <= 39 && !username.contains("_") && !username.contains(".")
                && !username.contains("--") && !username.hasSuffix("-")
        case .hackerNews: username.count <= 15 && !username.contains(".")
        case .gitlab, .dev: true
        default: matchesExpandedSyntax(username)
        }
    }

    /// Destinations are constructed locally, never taken from returned profile fields.
    func endpoint(_ username: String) -> URL? {
        guard !isManual, Self.username(username) == username, supports(username) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        switch self {
        case .github: parts.path = "/users/" + username
        case .gitlab:
            parts.path = "/api/v4/users"
            parts.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "per_page", value: "1")]
        case .hackerNews: parts.path = "/v0/user/" + username + ".json"
        case .dev:
            parts.path = "/api/users/by_username"
            parts.queryItems = [URLQueryItem(name: "url", value: username)]
        default: return expandedEndpoint(username)
        }
        return parts.url
    }

    func profileURL(_ username: String) -> URL? {
        guard Self.username(username) == username, supports(username) else { return nil }
        if let manualEntry {
            return manualEntry.profileURL(username)
        }
        var parts = URLComponents()
        parts.scheme = "https"
        switch self {
        case .github: parts.host = "github.com"; parts.path = "/" + username
        case .gitlab: parts.host = "gitlab.com"; parts.path = "/" + username
        case .hackerNews:
            parts.host = "news.ycombinator.com"; parts.path = "/user"
            parts.queryItems = [URLQueryItem(name: "id", value: username)]
        case .dev: parts.host = "dev.to"; parts.path = "/" + username
        default: return expandedProfileURL(username)
        }
        return parts.url
    }

    static func permits(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let provider = allCases.first(where: { $0.host == parts.host }) else { return false }
        let name: String? = if provider.mastodonHost != nil {
            parts.queryItems?.first(where: { $0.name == "acct" })?.value
        } else {
            switch provider {
            case .github: url.lastPathComponent
            case .gitlab: parts.queryItems?.first(where: { $0.name == "username" })?.value
            case .dev: parts.queryItems?.first(where: { $0.name == "url" })?.value
            case .hackerNews: String(url.lastPathComponent.dropLast(5))
            case .keybase: parts.queryItems?.first(where: { $0.name == "usernames" })?.value
            case .bluesky: Self.blueskyBase(parts.queryItems?.first(where: { $0.name == "actor" })?.value)
            case .mastodon: parts.queryItems?.first(where: { $0.name == "acct" })?.value
            default: url.lastPathComponent
            }
        }
        guard let name else { return false }
        return provider.endpoint(name) == url
    }
}

struct BeholderFinding: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case queued, checking, candidate, noResult, unsupported, limited, unavailable, cancelled, manual

        var title: String {
            switch self {
            case .queued: "Queued"
            case .checking: "Checking"
            case .candidate: "Candidate account"
            case .noResult: "No public result"
            case .unsupported: "Unsupported handle"
            case .limited: "Rate limited"
            case .unavailable: "Unavailable"
            case .cancelled: "Cancelled"
            case .manual: "Open manually · unchecked"
            }
        }
    }

    let provider: BeholderProvider
    var status: Status
    var checkedAt: Date?
    var sourceURL: URL?
    /// A prepared directory link, never a URL that Beholder requested or verified.
    var preparedProfileURL: URL?
    var fields: [String: String] = [:]
    var id: BeholderProvider {
        provider
    }
}

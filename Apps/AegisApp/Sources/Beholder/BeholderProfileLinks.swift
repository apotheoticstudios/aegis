import Foundation

/// Local canonical form for public HTTPS profile addresses the case already holds.
/// Nothing here fetches, resolves, follows or expands a link, and two equal addresses never prove two accounts are one person.
enum BeholderProfileLinks {
    /// Longest accepted address, in UTF-8 bytes (matches the evidence URL bound).
    static let maxLength = 2048
    /// Most inputs `deduplicate` reads; anything after is ignored, so work stays bounded.
    static let maxEntries = 500
    /// Longest source label `deduplicate` keeps, in UTF-8 bytes.
    static let maxSourceLength = 200

    /// How an entered address relates to a known source's profile address. Never an identity verdict.
    enum Relation: String, Sendable {
        /// Same canonical address.
        case exact
        /// A valid address that is not that one (it may still be the same account under another spelling).
        case different
        /// The entered address or the known profile address could not be put in canonical form.
        case unsupported
    }

    /// One distinct canonical address with the spelling and source it was first seen with.
    struct Entry: Equatable, Sendable {
        let canonical: URL
        let original: String
        let source: String
    }

    /// Lowercases scheme and host, drops a default `:443` and the fragment (never sent to a server), and keeps
    /// everything else exactly: path case, trailing slashes, `www`, query order and percent-encoded delimiters.
    /// Rejects anything that is not a plain public HTTPS address. The byte bound and the control/format check apply to
    /// the raw input; only ordinary spaces around it are then trimmed.
    static func canonical(_ input: String) -> URL? {
        guard input.utf8.count <= maxLength, visible(input) else { return nil }
        let text = input.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains),
              // Strict parsing: Foundation would otherwise repair a malformed escape such as "%zz" into "%25zz".
              let parts = URLComponents(string: text, encodingInvalidCharacters: false), parts.scheme?.lowercased() == "https",
              parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil, parts.port == nil || parts.port == 443,
              // The host is read from the text itself; Foundation decodes punycode and percent escapes in `host`.
              let authority = text.range(of: "://").map({ text[$0.upperBound...] }),
              let host = publicHost(String(authority.prefix { !"/?#:".contains($0) })),
              parts.encodedHost?.lowercased() == host,
              safeEncoding(parts.percentEncodedPath), parts.percentEncodedQuery.map(safeEncoding) ?? true,
              !hasDotSegment(parts.percentEncodedPath) else { return nil }
        var out = URLComponents()
        out.scheme = "https"
        out.encodedHost = host
        out.percentEncodedPath = parts.percentEncodedPath
        out.percentEncodedQuery = parts.percentEncodedQuery
        return out.url
    }

    /// Compares an owner-entered address with `provider`'s locally built profile address for `username`.
    static func relation(_ link: String, provider: BeholderProvider, username: String) -> Relation {
        guard let entered = canonical(link),
              let known = provider.profileURL(username).flatMap({ canonical($0.absoluteString) }) else { return .unsupported }
        return entered == known ? .exact : .different
    }

    /// Distinct valid addresses in first-seen order, each keeping its first spelling and source.
    /// Invalid addresses, and empty, oversized or hidden-character source labels, are skipped; at most `maxEntries` inputs are read.
    static func deduplicate(_ links: [(link: String, source: String)]) -> [Entry] {
        var seen = Set<URL>()
        var entries: [Entry] = []
        for item in links.prefix(maxEntries) {
            guard !item.source.isEmpty, item.source.utf8.count <= maxSourceLength, visible(item.source),
                  let url = canonical(item.link), seen.insert(url).inserted else { continue }
            entries.append(Entry(canonical: url, original: item.link, source: item.source))
        }
        return entries
    }

    /// RFC 3986 unreserved, reserved and `%`: printable ASCII without space, quotes, angle brackets, backslash or braces.
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    /// Suffixes that name private, local or non-public networks rather than public sites.
    private static let privateSuffixes: Set = [
        "local",
        "localhost",
        "internal",
        "invalid",
        "test",
        "onion",
        "lan",
        "home",
        "localdomain",
        "corp",
        "intranet",
        "arpa",
    ]

    /// A lowercased ASCII DNS name with exact labels, or nil for IP literals, encoded hosts and private names.
    private static func publicHost(_ raw: String) -> String? {
        guard let host = BeholderQueryPlanner.domain(raw),
              let last = host.split(separator: ".").last, !privateSuffixes.contains(String(last)) else { return nil }
        return host
    }

    /// No control (including newlines and tabs) or invisible format characters such as bidi overrides.
    private static func visible(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
    }

    /// Every `%` starts a valid escape, and the decoded text is UTF-8 without control or invisible format characters.
    private static func safeEncoding(_ component: String) -> Bool {
        component.removingPercentEncoding.map(visible) ?? false
    }

    /// `.` or `..` segments, plain or encoded, let a path read as one profile but resolve to another.
    private static func hasDotSegment(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains {
            [".", ".."].contains($0.removingPercentEncoding ?? String($0))
        }
    }
}

import Foundation

/// Navigation metadata for choosing sources: what a site is mainly for and how Beholder reaches it.
/// It is never evidence that an account exists, that a service works or who anyone is.
enum BeholderSourceGuide {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case social, developer, publishing, video, music, creative, gaming, interests, support

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .social: "Social networks"
            case .developer: "Developer & tech"
            case .publishing: "Writing & blogs"
            case .video: "Video & streaming"
            case .music: "Music & audio"
            case .creative: "Art, design & photos"
            case .gaming: "Games & chess"
            case .interests: "Hobbies & interests"
            case .support: "Creator support & link pages"
            }
        }

        /// Topic words a filter also matches, so "code" finds developer sources.
        var terms: [String] {
            switch self {
            case .social: ["social", "network", "microblog", "fediverse", "messaging", "community"]
            case .developer: ["code", "developer", "programming", "software", "tech", "containers"]
            case .publishing: ["blog", "writing", "newsletter", "articles", "fiction"]
            case .video: ["video", "streaming", "live", "channel"]
            case .music: ["music", "audio", "dj", "records", "lyrics", "playlists"]
            case .creative: ["art", "design", "photo", "portfolio", "illustration", "images"]
            case .gaming: ["games", "gaming", "chess"]
            case .interests: ["books", "film", "tv", "fitness", "learning", "reviews", "hobby"]
            case .support: ["donations", "membership", "tips", "links", "creator"]
            }
        }

        func matches(_ term: String) -> Bool {
            title.localizedStandardContains(term) || terms.contains { $0.localizedStandardContains(term) }
        }
    }

    enum Access: String, CaseIterable, Identifiable, Sendable {
        case all, automatic, manual

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .all: "All"
            case .automatic: "Automatic check"
            case .manual: "Open manually"
            }
        }

        func includes(_ provider: BeholderProvider) -> Bool {
            self == .all || (self == .manual) == provider.isManual
        }
    }

    /// Deliberately exhaustive: a new provider does not compile until someone files it under a category.
    static func category(_ provider: BeholderProvider) -> Category {
        switch provider {
        case .bluesky, .mastodon, .mastodonOnline, .mstdnSocial, .fosstodon, .hachyderm, .infosecExchange, .masTo, .socialVivaldi,
             .instagram, .twitter, .threads, .linkedIn, .snapchat, .reddit, .telegram, .minds, .vk, .myspace:
            .social
        case .github, .gitlab, .hackerNews, .dev, .codeberg, .dockerHub, .keybase, .scratch, .codePen, .productHunt:
            .developer
        case .writeAs, .tumblr, .medium, .wattpad, .substack:
            .publishing
        case .framaTube, .tiktok, .youtube, .twitch, .kick, .rumble, .vimeo, .dailymotion:
            .video
        case .mixcloud, .soundCloud, .bandcamp, .lastFm, .discogs, .spotify, .genius:
            .music
        case .pinterest, .deviantArt, .behance, .dribbble, .artStation, .flickr, .vsco, .imgur, .unsplash:
            .creative
        case .lichess, .chess, .steam:
            .gaming
        case .letterboxd, .goodreads, .strava, .trakt, .duolingo, .untappd:
            .interests
        case .patreon, .koFi, .buyMeACoffee, .aboutMe, .linktree:
            .support
        }
    }

    /// Text (name, host or topic), category and access combined, always in catalogue order.
    static func filter(
        _ text: String = "", category: Category? = nil, access: Access = .all,
        in providers: [BeholderProvider] = BeholderProvider.allCases
    ) -> [BeholderProvider] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = providers.filter { access.includes($0) && (category == nil || Self.category($0) == category) }
        guard !term.isEmpty else { return scoped }
        let named = Set(BeholderSources.matching(term, in: scoped))
        return scoped.filter { named.contains($0) || Self.category($0).matches(term) }
    }

    /// Adds only the listed sources; nothing outside them changes.
    static func select(_ visible: [BeholderProvider], in selected: Set<BeholderProvider>) -> Set<BeholderProvider> {
        selected.union(visible)
    }

    /// Removes only the listed sources; nothing outside them changes.
    static func deselect(_ visible: [BeholderProvider], in selected: Set<BeholderProvider>) -> Set<BeholderProvider> {
        selected.subtracting(visible)
    }

    static let caveat = "Categories describe what a site is mainly for. They are not evidence that an account exists, "
        + "that a service is working, or who anyone is."
}

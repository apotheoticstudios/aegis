import Foundation

/// A browser-only public profile link. Building it never contacts the site and never claims an account exists.
struct BeholderSocialEntry: Sendable {
    let id: String
    let title: String
    /// Fixed HTTPS host; the username only ever lands in the path.
    let host: String
    /// Unanchored ASCII rule for the whole username; `profileURL` anchors it.
    let pattern: String
    let pathPrefix: String
    var pathSuffix: String = ""
    /// Why this site stays a manual link rather than an automatic check.
    let reason: String

    func profileURL(_ username: String) -> URL? {
        guard !username.isEmpty, username.allSatisfy(\.isASCII),
              !username.hasPrefix("."), !username.contains(".."),
              !username.lowercased().hasSuffix(".bsky.social"),
              username.range(of: #"\A(?:"# + pattern + #")\z"#, options: .regularExpression) != nil
        else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = pathPrefix + username + pathSuffix
        return parts.url
    }
}

/// Manually opened social, creator and community profiles. URL shapes follow sherlock-project/sherlock
/// data.json (MIT) pinned at e40a45ec2a07 or the site's own docs; see docs/design/BEHOLDER-SOURCES.md.
enum BeholderSocialDirectory {
    private static let signIn = "Sign-in wall: logged-out pages hide or fake profiles."
    private static let blocked = "Bot protection makes automated checks unreliable."
    private static let soft = "Missing profiles still return a normal page, so only a person can judge it."
    private static let noAPI = "No keyless public profile API; the official API needs registration or keys."

    /// Stable order; IDs are frozen because Codex mirrors them as `BeholderProvider` cases.
    static let entries: [BeholderSocialEntry] = [
        .init(
            id: "instagram",
            title: "Instagram",
            host: "www.instagram.com",
            pattern: "[A-Za-z0-9._]{1,30}",
            pathPrefix: "/",
            pathSuffix: "/",
            reason: signIn
        ),
        .init(id: "x", title: "X (Twitter)", host: "x.com", pattern: "[A-Za-z0-9_]{1,15}", pathPrefix: "/", reason: signIn),
        .init(
            id: "facebook",
            title: "Facebook",
            host: "www.facebook.com",
            pattern: "[A-Za-z0-9.]{5,50}",
            pathPrefix: "/",
            reason: signIn
        ),
        .init(id: "tiktok", title: "TikTok", host: "www.tiktok.com", pattern: "[A-Za-z0-9_.]{2,24}", pathPrefix: "/@", reason: blocked),
        .init(id: "threads", title: "Threads", host: "www.threads.com", pattern: "[A-Za-z0-9._]{1,30}", pathPrefix: "/@", reason: signIn),
        .init(id: "youtube", title: "YouTube", host: "www.youtube.com", pattern: "[A-Za-z0-9_.-]{3,30}", pathPrefix: "/@", reason: noAPI),
        .init(
            id: "linkedIn",
            title: "LinkedIn",
            host: "www.linkedin.com",
            pattern: "[A-Za-z0-9-]{3,100}",
            pathPrefix: "/in/",
            reason: signIn
        ),
        .init(
            id: "pinterest",
            title: "Pinterest",
            host: "www.pinterest.com",
            pattern: "[A-Za-z0-9_]{3,30}",
            pathPrefix: "/",
            pathSuffix: "/",
            reason: soft
        ),
        .init(
            id: "snapchat",
            title: "Snapchat",
            host: "www.snapchat.com",
            pattern: "[A-Za-z][A-Za-z0-9._-]{1,13}[A-Za-z0-9]",
            pathPrefix: "/add/",
            reason: soft
        ),
        .init(id: "twitch", title: "Twitch", host: "www.twitch.tv", pattern: "[A-Za-z0-9_]{4,25}", pathPrefix: "/", reason: noAPI),
        .init(id: "reddit", title: "Reddit", host: "www.reddit.com", pattern: "[A-Za-z0-9_-]{3,20}", pathPrefix: "/user/", reason: blocked),
        .init(id: "tumblr", title: "Tumblr", host: "www.tumblr.com", pattern: "[A-Za-z0-9-]{1,32}", pathPrefix: "/", reason: noAPI),
        .init(
            id: "telegram",
            title: "Telegram",
            host: "t.me",
            pattern: "[A-Za-z][A-Za-z0-9_]{3,30}[A-Za-z0-9]",
            pathPrefix: "/",
            reason: soft
        ),
        .init(id: "medium", title: "Medium", host: "medium.com", pattern: "[A-Za-z0-9_.]{1,30}", pathPrefix: "/@", reason: blocked),
        .init(
            id: "soundCloud",
            title: "SoundCloud",
            host: "soundcloud.com",
            pattern: "[A-Za-z0-9_-]{3,25}",
            pathPrefix: "/",
            reason: noAPI
        ),
        .init(id: "bandcamp", title: "Bandcamp (fan)", host: "bandcamp.com", pattern: "[A-Za-z0-9_-]{1,50}", pathPrefix: "/", reason: soft),
        .init(
            id: "steam",
            title: "Steam Community",
            host: "steamcommunity.com",
            pattern: "[A-Za-z0-9_-]{2,32}",
            pathPrefix: "/id/",
            pathSuffix: "/",
            reason: soft
        ),
        .init(
            id: "deviantArt",
            title: "DeviantArt",
            host: "www.deviantart.com",
            pattern: "[A-Za-z][A-Za-z0-9_-]{2,19}",
            pathPrefix: "/",
            reason: blocked
        ),
        .init(id: "behance", title: "Behance", host: "www.behance.net", pattern: "[A-Za-z0-9_-]{3,40}", pathPrefix: "/", reason: blocked),
        .init(
            id: "dribbble",
            title: "Dribbble",
            host: "dribbble.com",
            pattern: "[A-Za-z][A-Za-z0-9_-]{1,39}",
            pathPrefix: "/",
            reason: soft
        ),
        .init(
            id: "artStation",
            title: "ArtStation",
            host: "www.artstation.com",
            pattern: "[A-Za-z0-9_-]{1,63}",
            pathPrefix: "/",
            reason: blocked
        ),
        .init(id: "flickr", title: "Flickr", host: "www.flickr.com", pattern: "[A-Za-z0-9_-]{1,63}", pathPrefix: "/people/", reason: noAPI),
        .init(id: "vsco", title: "VSCO", host: "vsco.co", pattern: "[A-Za-z0-9_-]{1,30}", pathPrefix: "/", reason: blocked),
        .init(
            id: "letterboxd",
            title: "Letterboxd",
            host: "letterboxd.com",
            pattern: "[A-Za-z0-9_]{2,15}",
            pathPrefix: "/",
            pathSuffix: "/",
            reason: blocked
        ),
        .init(
            id: "lastFm",
            title: "Last.fm",
            host: "www.last.fm",
            pattern: "[A-Za-z][A-Za-z0-9_-]{1,14}",
            pathPrefix: "/user/",
            reason: noAPI
        ),
        .init(id: "goodreads", title: "Goodreads", host: "www.goodreads.com", pattern: "[A-Za-z0-9_]{1,40}", pathPrefix: "/", reason: soft),
        .init(
            id: "wattpad",
            title: "Wattpad",
            host: "www.wattpad.com",
            pattern: "[A-Za-z0-9_-]{1,20}",
            pathPrefix: "/user/",
            reason: blocked
        ),
        .init(
            id: "strava",
            title: "Strava",
            host: "www.strava.com",
            pattern: "[A-Za-z0-9_-]{1,40}",
            pathPrefix: "/athletes/",
            reason: signIn
        ),
        .init(id: "patreon", title: "Patreon", host: "www.patreon.com", pattern: "[A-Za-z0-9_]{1,64}", pathPrefix: "/", reason: blocked),
        .init(id: "koFi", title: "Ko-fi", host: "ko-fi.com", pattern: "[A-Za-z0-9_]{1,40}", pathPrefix: "/", reason: soft),
        .init(
            id: "buyMeACoffee",
            title: "Buy Me a Coffee",
            host: "buymeacoffee.com",
            pattern: "[A-Za-z0-9]{3,15}",
            pathPrefix: "/",
            reason: blocked
        ),
        .init(id: "aboutMe", title: "About.me", host: "about.me", pattern: "[A-Za-z0-9_-]{1,40}", pathPrefix: "/", reason: soft),
        .init(
            id: "substack",
            title: "Substack",
            host: "substack.com",
            pattern: "[A-Za-z0-9][A-Za-z0-9_-]{1,60}",
            pathPrefix: "/@",
            reason: soft
        ),
        .init(id: "kick", title: "Kick", host: "kick.com", pattern: "[A-Za-z0-9_]{3,25}", pathPrefix: "/", reason: blocked),
        .init(id: "rumble", title: "Rumble", host: "rumble.com", pattern: "[A-Za-z0-9_-]{1,40}", pathPrefix: "/user/", reason: blocked),
        .init(
            id: "minds",
            title: "Minds",
            host: "www.minds.com",
            pattern: "[A-Za-z0-9_]{1,50}",
            pathPrefix: "/",
            pathSuffix: "/",
            reason: soft
        ),
        .init(id: "vk", title: "VK", host: "vk.com", pattern: "[A-Za-z][A-Za-z0-9_.]{4,31}", pathPrefix: "/", reason: signIn),
        .init(
            id: "mixcloud",
            title: "Mixcloud",
            host: "www.mixcloud.com",
            pattern: "[A-Za-z0-9_-]{1,50}",
            pathPrefix: "/",
            pathSuffix: "/",
            reason: noAPI
        ),
        // Must start with a letter: an all-digit path is a video, not a profile.
        .init(id: "vimeo", title: "Vimeo", host: "vimeo.com", pattern: "[A-Za-z][A-Za-z0-9_]{2,63}", pathPrefix: "/", reason: noAPI),
        .init(
            id: "dailymotion",
            title: "Dailymotion",
            host: "www.dailymotion.com",
            pattern: "[A-Za-z0-9_-]{3,30}",
            pathPrefix: "/",
            reason: noAPI
        ),
        .init(id: "linktree", title: "Linktree", host: "linktr.ee", pattern: "[A-Za-z0-9_.]{2,30}", pathPrefix: "/", reason: soft),
        .init(id: "imgur", title: "Imgur", host: "imgur.com", pattern: "[A-Za-z0-9]{4,63}", pathPrefix: "/user/", reason: noAPI),
        .init(
            id: "discogs",
            title: "Discogs",
            host: "www.discogs.com",
            pattern: "[A-Za-z0-9_.-]{1,40}",
            pathPrefix: "/user/",
            reason: blocked
        ),
        .init(id: "trakt", title: "Trakt", host: "www.trakt.tv", pattern: "[A-Za-z0-9_-]{1,40}", pathPrefix: "/users/", reason: noAPI),
        .init(
            id: "duolingo",
            title: "Duolingo",
            host: "www.duolingo.com",
            pattern: "[A-Za-z0-9_-]{1,40}",
            pathPrefix: "/profile/",
            reason: soft
        ),
        .init(id: "unsplash", title: "Unsplash", host: "unsplash.com", pattern: "[a-z0-9_]{1,60}", pathPrefix: "/@", reason: noAPI),
        .init(id: "untappd", title: "Untappd", host: "untappd.com", pattern: "[A-Za-z0-9_-]{1,40}", pathPrefix: "/user/", reason: blocked),
        .init(id: "codePen", title: "CodePen", host: "codepen.io", pattern: "[A-Za-z0-9_-]{1,40}", pathPrefix: "/", reason: blocked),
        .init(
            id: "productHunt",
            title: "Product Hunt",
            host: "www.producthunt.com",
            pattern: "[A-Za-z0-9_]{1,40}",
            pathPrefix: "/@",
            reason: blocked
        ),
        .init(id: "myspace", title: "Myspace", host: "myspace.com", pattern: "[A-Za-z0-9_.-]{1,40}", pathPrefix: "/", reason: soft),
        .init(
            id: "spotify",
            title: "Spotify (user)",
            host: "open.spotify.com",
            pattern: "[A-Za-z0-9_.-]{1,64}",
            pathPrefix: "/user/",
            reason: noAPI
        ),
        .init(id: "genius", title: "Genius", host: "genius.com", pattern: "[A-Za-z0-9]{1,40}", pathPrefix: "/", reason: soft),
    ]

    static func entry(id: String) -> BeholderSocialEntry? {
        entries.first { $0.id == id }
    }
}

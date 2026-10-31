# Beholder social directory (manual links)

`Apps/AegisApp/Sources/Beholder/BeholderSocialDirectory.swift` builds browser-only public profile links for 48 social, creator and community sites (issue #104). It is a local URL builder:

- No network code. Selecting a source or pressing Search never contacts these sites; the owner clicks one specific link and the browser opens it.
- No existence claims. A link means "this is where a profile with that handle would be", never "an account exists" or "this is the same person".
- Fixed hosts. Every entry has one hard-coded HTTPS host; the username only fills the path. No subdomain sites (artist-subdomain Bandcamp, itch.io, Tumblr and Substack blogs), no redirects, no shorteners.
- Strict input. ASCII only, matched in full against the site's anchored rule; slashes, queries, fragments, percent escapes, `@`, `:`, spaces, controls, a leading `.` and `..` cannot pass. Qualified `*.bsky.social` names are refused on every site (they belong to the Bluesky source).

The issue's frozen IDs are the `id` column below, in directory order.

## Method and provenance

URL shapes and most username rules come from [sherlock-project/sherlock `data.json`](https://github.com/sherlock-project/sherlock/blob/e40a45ec2a074b90703b3b4b842c8a3adbd6ada3/sherlock_project/resources/data.json) (MIT), pinned at commit `e40a45e`. Only per-site URL patterns were used as facts; no Sherlock code, rules runtime or dataset is copied or shipped. Where Sherlock gives no `regexCheck`, the rule is a conservative character set from the site's own username guidance, wide enough for real handles; a too-wide rule only yields a link that shows "not found" in the browser.

Departures from the pinned data:

| Site | Sherlock | Here | Why |
| --- | --- | --- | --- |
| Instagram, LinkedIn, Last.fm | bare domain | `www.` host | canonical host, no redirect |
| Threads | `www.threads.net` | `www.threads.com` | [Meta: "We're migrating from Threads.net to Threads.com"](https://about.fb.com/news/2025/04/new-features-threads-web-experience/) |
| Buy Me a Coffee | `buymeacoff.ee` (shortener) | `buymeacoffee.com` | no shortener redirect |
| LinkedIn | `[a-zA-Z0-9]{3,100}` | adds `-` | generated public URLs contain hyphens |
| Vimeo | any | must start with a letter | an all-digit path is a video |

Sherlock's detection method (`status_code`, `message`, `response_url`) only informed the "why manual" column. None of these entries is ever searched.

## Directory

Why manual: **sign-in** = sign-in walls can hide or change logged-out profile pages; **bot** = bot protection can make automated checks unreliable; **soft** = missing profiles may still return a normal page; **API** = automatic checking is not configured for this site here (a keyless API may exist).

| id | Site | Link | Why manual |
| --- | --- | --- | --- |
| instagram | Instagram | `www.instagram.com/{}/` | sign-in |
| x | X (Twitter) | `x.com/{}` | sign-in |
| tiktok | TikTok | `www.tiktok.com/@{}` | bot |
| threads | Threads | `www.threads.com/@{}` | sign-in |
| youtube | YouTube | `www.youtube.com/@{}` | API |
| linkedIn | LinkedIn | `www.linkedin.com/in/{}` | sign-in |
| pinterest | Pinterest | `www.pinterest.com/{}/` | soft |
| snapchat | Snapchat | `www.snapchat.com/add/{}` | soft |
| twitch | Twitch | `www.twitch.tv/{}` | API |
| reddit | Reddit | `www.reddit.com/user/{}` | bot |
| telegram | Telegram | `t.me/{}` | soft |
| medium | Medium | `medium.com/@{}` | bot |
| soundCloud | SoundCloud | `soundcloud.com/{}` | API |
| bandcamp | Bandcamp (fan) | `bandcamp.com/{}` | soft |
| steam | Steam Community | `steamcommunity.com/id/{}/` | soft |
| deviantArt | DeviantArt | `www.deviantart.com/{}` | bot |
| behance | Behance | `www.behance.net/{}` | bot |
| dribbble | Dribbble | `dribbble.com/{}` | soft |
| artStation | ArtStation | `www.artstation.com/{}` | bot |
| flickr | Flickr | `www.flickr.com/people/{}` | API |
| vsco | VSCO | `vsco.co/{}` | bot |
| letterboxd | Letterboxd | `letterboxd.com/{}/` | bot |
| lastFm | Last.fm | `www.last.fm/user/{}` | API |
| goodreads | Goodreads | `www.goodreads.com/{}` | soft |
| wattpad | Wattpad | `www.wattpad.com/user/{}` | bot |
| strava | Strava | `www.strava.com/athletes/{}` | sign-in |
| patreon | Patreon | `www.patreon.com/{}` | bot |
| koFi | Ko-fi | `ko-fi.com/{}` | soft |
| buyMeACoffee | Buy Me a Coffee | `buymeacoffee.com/{}` | bot |
| aboutMe | About.me | `about.me/{}` | soft |
| kick | Kick | `kick.com/{}` | bot |
| rumble | Rumble | `rumble.com/user/{}` | bot |
| minds | Minds | `www.minds.com/{}/` | soft |
| vk | VK | `vk.com/{}` | sign-in |
| vimeo | Vimeo | `vimeo.com/{}` | API |
| dailymotion | Dailymotion | `www.dailymotion.com/{}` | API |
| linktree | Linktree | `linktr.ee/{}` | soft |
| imgur | Imgur | `imgur.com/user/{}` | API |
| discogs | Discogs | `www.discogs.com/user/{}` | bot |
| trakt | Trakt | `www.trakt.tv/users/{}` | API |
| duolingo | Duolingo | `www.duolingo.com/profile/{}` | soft |
| unsplash | Unsplash | `unsplash.com/@{}` | API |
| untappd | Untappd | `untappd.com/user/{}` | bot |
| codePen | CodePen | `codepen.io/{}` | bot |
| productHunt | Product Hunt | `www.producthunt.com/@{}` | bot |
| myspace | Myspace | `myspace.com/{}` | soft |
| spotify | Spotify (user) | `open.spotify.com/user/{}` | API |
| genius | Genius | `genius.com/{}` | soft |

## Left out

Facebook, Tumblr (`www.tumblr.com/{}`) and Substack (`substack.com/@{}`) were dropped: the pinned data has no fixed-host route for them and no primary source for one was found, so no route was invented. Mixcloud moved to an automatic source (keyless `api.mixcloud.com`, #105). Also not in the pinned data and no official rule checked: Gab, GETTR, Truth Social, OK (ok.ru), Weibo (profile paths use numeric IDs or non-ASCII nicknames), 500px. Disqus was left out because the pinned pattern (`disqus.com/{}`) conflicts with Disqus's own `/by/{}` profile path. The existing twelve automatic sources (GitHub, GitLab, Hacker News, DEV, Codeberg, Docker Hub, Keybase, Lichess, Chess.com, Scratch, Bluesky, Mastodon.social) are not repeated. Adult sites and Sherlock's non-social entries are out of scope.

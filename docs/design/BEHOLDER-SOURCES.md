# Beholder social directory (manual links)

`Apps/AegisApp/Sources/Beholder/BeholderSocialDirectory.swift` builds browser-only public profile links for 50 social, creator and community sites (issue #104). It is a local URL builder:

- No network code. Selecting a source or pressing Search never contacts these sites; the owner clicks one specific link and the browser opens it.
- No existence claims. A link means "this is where a profile with that handle would be", never "an account exists" or "this is the same person".
- Fixed hosts. Every entry has one hard-coded HTTPS host; the username only fills the path. No subdomain sites (artist-subdomain Bandcamp, itch.io, Tumblr and Substack blog subdomains) and no shorteners. The builder itself never fetches or follows redirects; the owner's browser may redirect normally once they open a link.
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
| Tumblr | `{}.tumblr.com` | `tumblr.com/{}` | [Tumblr Help](https://help.tumblr.com/knowledge-base/web-notifications/) gives `https://tumblr.com/username`; subdomains redirect there |
| Substack | `{}.substack.com` (publication) | `substack.com/@{}`, `[A-Za-z0-9]{4,32}` | [Substack: What are Substack Handles?](https://support.substack.com/hc/en-us/articles/15574565677204-What-are-Substack-Handles) (letters and numbers, 4–32), also [How can I publish on Substack](https://support.substack.com/hc/en-us/articles/29152946791188-How-can-I-publish-on-Substack) |
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
| tumblr | Tumblr | `tumblr.com/{}` | API |
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
| substack | Substack | `substack.com/@{}` | soft |
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

Facebook was dropped: the pinned data has no route for it and no primary source was linked, so no route was invented. Mixcloud moved to an automatic source (keyless `api.mixcloud.com`, #105). Also not in the pinned data and no official rule checked: Gab, GETTR, Truth Social, OK (ok.ru), Weibo (profile paths use numeric IDs or non-ASCII nicknames), 500px. Disqus was left out because the pinned pattern (`disqus.com/{}`) conflicts with Disqus's own `/by/{}` profile path. The existing twelve automatic sources (GitHub, GitLab, Hacker News, DEV, Codeberg, Docker Hub, Keybase, Lichess, Chess.com, Scratch, Bluesky, Mastodon.social) are not repeated. Adult sites and Sherlock's non-social entries are out of scope.

## Self-check: opt-out pages (#139)

The Self-check tab lists pages where an Australian can see or limit what is held about them. It only shows links. Beholder never contacts, searches or scrapes these sites, and never sends them anything; the owner opens a page in the browser. The tab's "Check on all sources" runs the ordinary username search on the owner's own handle, with the usual preview and Stop.

Each page was confirmed on its own site on 2026-11-02.

| id | Place | Page | Confirmed |
| --- | --- | --- | --- |
| experian | Experian Australia: marketing data opt-out form | `www.experian.com.au/data-and-marketing/consumer-opt-out` | the form page itself |
| equifax | Equifax Do Not Contact: phone, mail and email marketing, and pre-screened credit offers (run by Equifax Australia Marketing Services) | `www.donotcontact.com.au/` | named as the opt-out form in [Equifax's credit reporting policy](https://www.equifax.com.au/credit-reporting-policy) |
| cotality | Cotality (formerly CoreLogic): property data; access, correction and marketing-list removal through its privacy officer | `www.cotality.com/au/legal/privacy-policy` | the policy itself |
| doNotCall | Do Not Call Register (ACMA) | `www.donotcall.gov.au/consumers/register-your-numbers/` | linked from the register's home page |
| silentElector | Silent elector (AEC): address kept off future public rolls; needs a statutory declaration of a safety risk | `www.aec.gov.au/Enrolling_to_vote/Special_Category/silent-electors.htm` | the AEC page itself |
| haveIBeenPwned | Have I Been Pwned: the owner types their own email on its site | `haveibeenpwned.com/` | the site itself |

Left out, with no route invented:
- White Pages Australia and Reverse Australia: no official removal page found. Listings generally come from phone providers, so ask your provider for an unlisted (silent) number.
- illion: now part of Experian, with no separate opt-out page found.
- Spokeo and other US people-search sites: mostly US records, and their pages couldn't be confirmed.

**Breach checks inside Beholder stay off.** [Have I Been Pwned's API](https://haveibeenpwned.com/API/v3) needs a paid subscription key for searches by email address. It doesn't require proof that the address is yours, and its acceptable use forbids querying data in order to harm breach victims. An in-app check would send an email address off the Mac, so it needs the owner's key and its own ADR first.

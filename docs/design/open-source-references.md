# Open-source reference projects (issue #37)

Projects that read the same macOS stores as Aegis, or build similar local briefs. They're used to check the readers' **hypothetical** layouts before the owner's real-data trial (#19), and to borrow proven ideas. Researched 2026-10-08; licences checked on GitHub and crates.io that day.

**Licence rule.** From any project we may learn *facts*: table and column names, numeric codes, file layouts. Code may be copied only from permissive licences (MIT, Apache-2.0), with attribution and an ADR. Nothing is copied from GPL, AGPL, custom or unlicensed projects. That is why the Messages text decoder was written from the format's description.

**Evidence levels.** **Verified** means read in the project's source or docs here. **Reported** means it comes from others' write-ups and hasn't been checked; the owner's runs (#4, #19) are the final check.

## Mail: Envelope Index and `.emlx` files

| Project | Licence | What it is |
| --- | --- | --- |
| [claude-connector-apple-mail](https://github.com/falconbradley/claude-connector-apple-mail) | MIT | Python MCP server reading the Envelope Index and `.emlx` directly; active (updated 2026-10-06) |
| [imdinu/apple-mail-mcp](https://github.com/imdinu/apple-mail-mcp) (formerly jxa-mail-mcp) | GPL-3.0 | MCP server; full-text search index over `.emlx` bodies |

Verified in claude-connector-apple-mail (`src/apple_mail_mcp/envelope.py`):
- **The Envelope Index layout varies between macOS releases**, so it inspects the columns at runtime (`PRAGMA table_info`) instead of assuming them.
- When the `read`, `flagged` or `deleted` columns are missing, it uses bits in `messages.flags` instead: read `1 << 0`, deleted `1 << 1`, flagged `1 << 4`.
- **Dates:** Unix seconds on modern macOS, seconds since 2001 on older builds. It decides from `MAX(date_received)` (above 1e9 means Unix).
- **Files:** one walk of the `V*` folder indexes `<ROWID>.emlx`, preferring a complete file over `<ROWID>.partial.emlx`. The file name is the `messages` ROWID.
- It opens the index read-only with `PRAGMA query_only`.

Reported (several agent-skill write-ups; unverified):
- **Real layout:** `V10/<account UUID>/<mailbox>.mbox/<UUID>/Data/<digits>/Messages/<ROWID>.emlx`.
  - The `<digits>` folders come from `ROWID // 1000`, reversed, one digit per level. For example, 258226 is stored as `Data/8/5/2/Messages/258226.emlx`; small mailboxes have just `Data/Messages/`.
- **Partial downloads:** `.partial.emlx` holds the headers and part of the body; attachments not yet downloaded sit beside it as `.emlxpart` files.

**What this means for Aegis (#16):**
- Don't require a `deleted` column; fall back to the `flags` bit.
- Detect the date epoch from the data.
- Keep the single folder walk; it handles any depth.
- Ignore `.emlxpart` files.
- The fixture's flat `Data/Messages/` matches a small mailbox.

## Messages: `chat.db`

| Project | Licence | What it is |
| --- | --- | --- |
| [imessage-exporter](https://github.com/ReagentX/imessage-exporter) and its libraries `imessage-database`, `crabstep` | GPL-3.0 (crates: GPL-3.0-or-later) | The most complete reader; `crabstep` decodes the `attributedBody` typedstream. **Facts only.** |
| [BlueBubbles Server](https://github.com/BlueBubblesApp/bluebubbles-server) | Apache-2.0 | Bridges Messages to other devices and decodes `attributedBody` in TypeScript; a permissive cross-check for our decoder |
| [jons-mcp-imessage](https://github.com/jonmmease/jons-mcp-imessage) | none (all rights reserved) | Has a useful format write-up (`docs/IMESSAGE_DATABASE_FORMAT.md`). **Facts only.** |

Verified (imessage-exporter's `docs/tables/messages.md` and `imessage-database` source; jons-mcp-imessage's format notes):
- **`message.item_type`** (0 is an ordinary message):
  - 1: a person was added (`group_action_type` 0) or removed (1);
  - 2: the group was renamed (`group_title`);
  - 3: someone left (0), the group photo changed (1) or was removed (2), or the background changed (4) or was removed (6);
  - 4: location sharing started or stopped;
  - 5: an audio message was kept;
  - 6: SharePlay or FaceTime.
- **`associated_message_type`:**
  - 1000: a sticker placed on a message;
  - 2000–2007: reaction added (2006 emoji, 2007 sticker);
  - 3000–3007: the same reactions removed;
  - 4000: a poll vote.
- The real table also has `is_system_message`, `date_retracted` (unsent), `date_edited`, `thread_originator_guid` and `balloon_bundle_id`.
- **Chat GUIDs:** `iMessage;-;<handle>` or `SMS;-;<handle>` for one-to-one, `iMessage;+;chat<digits>` for groups. Dates are seconds or nanoseconds since 2001 depending on the macOS version.

**What this means for Aegis (#15):**
- Skip rows with `item_type` other than 0 (group events and similar have no text), and report them as `system_item_skipped`.
- Report unsent messages (`date_retracted` set) as `unsent_skipped`.
- Also skip association types 1000 and 4000, alongside reactions.
- The fixture's GUID formats and date rules match the real ones.

## Notification Center database

| Project | Licence | What it is |
| --- | --- | --- |
| [Plaso](https://plaso.readthedocs.io/en/stable/_modules/plaso/parsers/sqlite_plugins/macos_notification_center.html) (log2timeline) | Apache-2.0 | Forensic timeline tool with a Notification Center parser |
| [mac_apt](https://github.com/ydkhatri/mac_apt) | MIT | macOS forensics framework with a NOTIFICATIONS plugin |

Verified (Plaso's parser):
- It reads `app(identifier, app_id)` joined to `record(data, delivered_date, presented, app_id)`.
- From the binary-plist `data` it reads `req` → `titl`, `subt`, `body`. Times are seconds since 2001.
- It documents the older location `/private/var/folders/…/0/com.apple.notificationcenter/db2/db`. On macOS 15+ the probe uses `~/Library/Group Containers/group.com.apple.usernoted/db2/db`.

**What this means for Aegis:**
- The fixture layout matches an independent, maintained parser; the owner's `schema` run (#4) remains the final check.
- Plaso uses an inner join, dropping records whose app row is missing; our reader keeps them.
- Plaso also keeps the subtitle (`subt`), which matters for Mail and some group notifications. Whether schema 0.1 should carry it is still a question for #19.

## Local assistants that brief from personal data (ideas only)

| Project | Licence | Relevant idea |
| --- | --- | --- |
| [screenpipe](https://github.com/screenpipe/screenpipe) | custom (moved off MIT) | Local capture into SQLite, daily summaries and action items from local models, on Apple silicon |
| [Khoj](https://github.com/khoj-ai/khoj) | AGPL-3.0 | Personal AI over documents and email; retrieval before generation |
| [Inbox Zero](https://github.com/elie222/inbox-zero) | custom | Email triage categories and "needs reply" detection (cloud mail, not local stores) |

None reads the macOS stores the way Aegis does. They are references for brief structure and triage categories, not for code.

## World view: public-data dashboards (#115)

Projects the owner shared on 2026-10-31 for ideas for the World view. Read on GitHub that day (README, licence, feature list); none was run.

| Project | Licence | What it is |
| --- | --- | --- |
| [worldmonitor](https://github.com/koala73/worldmonitor) | AGPL-3.0-only | News and geopolitics dashboard (globe.gl and deck.gl), AI briefs from curated feeds, a Country Instability Index, finance variants, a Tauri desktop app. **Ideas only.** |
| [OSIRIS](https://github.com/simplifaisoul/osiris) | MIT | Next.js and MapLibre OSINT map: flights, CCTV, quakes, fires, NASA EONET, NOAA space weather, news streams, a hand-kept conflict-zone list, plus a recon toolkit and crypto tracing. Code could be copied with attribution and an ADR, but none is: Aegis's versions are a few lines each. Its repo description carries a crypto token address, so treat its links and dependencies with care. MIT covers its code, not the data of the sources it lists. |
| [Crucix](https://github.com/calesthio/Crucix) | AGPL-3.0 | Node "intelligence terminal": 27 public feeds swept every 15 minutes, a sweep delta (what's new, escalated or eased), FLASH/PRIORITY/ROUTINE alert tiers, Telegram and Discord bots. **Ideas only.** |

What Aegis took (#115, all re-implemented):
- **Space weather** (OSIRIS uses NOAA SWPC): NOAA's Kp forecast, with whether aurora may be seen from home.
- **More disaster types** (all three aggregate disasters): Aegis's existing GDACS request now covers all its types.
- **What's new** (Crucix's sweep delta): regional alerts leave the brief 12 hours after they first appear, unless they escalate.

- **World headlines on the globe** (#116; worldmonitor's and Crucix's news layers): GDELT's map API is retired (404), and its article API has no locations and allows one request every 5 seconds. So Aegis follows OSIRIS's approach instead: public RSS headlines (BBC World, Al Jazeera) matched to the countries they name.

Left out:
- **God's Eye View already has them:** flights, ships, satellites, quakes, fires, cameras, air quality, radio.
- **Off-mission:** markets, trade ideas, crypto tracing, sanctions search, the port-scan and WHOIS toolkit.
- **Against Aegis's rules:** scraping Telegram, Reddit or Bluesky; Telegram and Discord push alerts (Aegis is silent until opened); cloud AI keys.
- **Not worth it:** the hand-kept conflict-zone list (political, goes stale), and radiation sensors (little value in Australia).

## Defending against instructions planted in collected text

- **Spotlighting** (Microsoft, [arXiv 2403.14720](https://arxiv.org/abs/2403.14720)):
  - **Delimiting:** marking where untrusted text starts and ends.
  - **Datamarking:** interleaving a marker character through it.
  - **Encoding:** e.g. base64.

  On GPT models these cut attack success from above 50% to below 2%. Aegis already encodes each body as a JSON string on one line (#36). Datamarking is a cheap experiment for the planted-instruction finding (day-5 gate question 2).
- **CaMeL** (Google DeepMind, 2025, [paper](https://css.csail.mit.edu/6.858/2026/readings/camel.pdf)): a privileged model plans, and a quarantined model reads untrusted data but has no tools. Capabilities attached to data decide where it may flow. Aegis's rule that briefs carry no actions follows the same idea. CaMeL becomes relevant when Aegis gains actions (the action safety system).

## Follow-ups
1. **Mail reader (#16 follow-up):**
   - make `deleted` optional (flags-bit fallback) and detect the date epoch;
   - never drop a message over a header defect (fall back to the raw header text);
   - handle HTML without `</head>`.
2. **Messages reader (#15 follow-up):** skip system rows (`item_type` ≠ 0), unsent messages, and association types 1000 and 4000, with problem codes.
3. **Brief (day-5 gate):** test datamarking against the planted-instruction cases.
4. **Trial (#19):** check the reported Mail folder layout and the notification subtitle question on real data.

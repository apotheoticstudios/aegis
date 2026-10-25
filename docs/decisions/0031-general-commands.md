# ADR-0031: General commands through a closed set of typed abilities

- **Status:** Accepted (owner's design choice, 2026-10-23)
- **Issue:** #39 (slice 1: websites and shortcuts), #43 (slice 2: files and folders, the app automation catalogue)

## Context

Every action Aegis can take is hand-written: one parser and one executor each for reminders, events, opening apps and messages. The owner wants Aegis to do almost anything macOS allows, for example "run the Work shortcut" or "open apple.com", without code for each request. ADR-0016's pipeline (owner words → typed request → policy → confirmation → executor → codes-only log) stays. What changes is how words reach a typed request, and which requests exist.

## Options considered

1. Keep hand-writing one action at a time. Safe, but it never reaches "almost anything".
2. Let the local model write AppleScript, shell commands or URLs with any scheme. That gives reach, but it is arbitrary code from a model, and no policy can judge it.
3. Hand requests to Siri. macOS has no public way for an app to ask Siri something. The routes are private frameworks (forbidden) or typing into "Type to Siri" through Accessibility, which is fragile and can send the owner's words to Apple's servers. Most of what Siri does in apps comes from App Intents, and those are what Shortcuts runs, so option 4 reaches the same app actions by public means.
4. A small, closed set of general **abilities**, each a typed `ActionPayload` the policy can judge. Fixed phrases map to them directly. Otherwise the local model picks one ability from a catalogue.

## Decision

Option 4.

| Ability | Payload | Route (public, documented) | Tier |
| --- | --- | --- | --- |
| Open an app | `.app(bundleID:, .open)` (existing) | NSWorkspace | auto |
| Open a website | `.website(url:, .open)` | NSWorkspace opens an http(s) address in the default browser | auto |
| Run a shortcut | `.shortcut(name:, .run)` | `/usr/bin/shortcuts run <name>` (Apple's command-line tool), exact name from `shortcuts list` | auto (owner's choice); never when the name sounds like paying, buying, ordering, transferring money, deleting or passwords |
| Open a file or folder | `.file(path:, .open)` (existing) | NSWorkspace. Found by a well-known folder name ("Downloads", "iCloud Drive") or by Spotlight (`NSMetadataQuery`) on file names only, never contents; an exact name first, then the one used most recently (owner's choice) | auto, inside the home folder (Library allowed, owner's choice; hidden folders not); `never` for files that run code or install something (scripts, apps, installers, profiles, link files) |
| App automation | `.automation(AppAutomation, argument:)`, one `AppAutomation` case per catalogue entry, verb `run` | Fixed Apple Events per app through `/usr/bin/osascript`, the one typed argument passed as `argv`, never model-written scripts. Finder reveal uses NSWorkspace | auto (owner's choice, #43) |
| App links (#45) | `.automation(.mapsDirections / .mapsSearch / .settingsPage, argument:)` | Apple Maps' documented `maps:` link with the owner's words as one encoded value; System Settings pages by `x-apple.systempreferences:` from a fixed list of 27 pages (`SettingsPage`), never arbitrary schemes. A page only opens: Aegis never changes a setting there | auto (owner's choice, #45) |
| System controls (#45) | `.automation(.volumeSet / .volumeUp / .volumeDown / .mute / .unmute / .darkMode / .lightMode, argument:)` | Standard Additions `set volume` through `osascript` (a whole number 0–100 as `argv`); dark mode through System Events (macOS asks once) | auto (owner's choice, #45) |

**Words to ability.** Fixed phrases come first and need no model: "open apple.com", "go to bom.gov.au", "run the Work shortcut", "run Work" (when a shortcut has exactly that name). If nothing else in Aegis takes a command-like request (it starts with run, open, start, go to, turn and similar), the local model picks at most one ability from a catalogue that lists the abilities and the owner's shortcut names (`CoreRequest.commandPlan`, the same pattern as the World view's `worldPlan`, #296). The reply is checked strictly: a known ability; for a shortcut, a name from the list exactly; for a website, an http(s) address with a real host; for an app, a short name. Anything else is dropped and the question is answered as usual.

**The app automation catalogue (#43, agreed with the owner 2026-10-23).** Music: play, pause, next, previous, play a playlist by name. Notes: a new note with a title. Safari: an http(s) address in a new tab. Finder: show a file or folder from the home folder. Phrases: "pause the music", "next song", "play my Running playlist", "make a note called Groceries", "open apple.com in a new Safari tab", "show the Budget spreadsheet in Finder". macOS asks once per app before Aegis may control it (Automation).

**Plans (#47, owner's choice 2026-10-23: show the plan, one OK).** Several requests in one line ("open Safari, go to apple.com and play music") are split into parts (`CommandPlan.parts`): a part joins the one before it unless it reads as a command of its own, free text (a message, a reminder, an event, a note's title) ends only at "then" or ";", every part must be a command, and there are at most six. Each part is worked out as a single request would be (fixed phrases, then apps, shortcuts and files, then the local model) and judged by `ActionPolicy` before the card shows. Never-list parts and parts Aegis can't work out are left out, and the card says so. One card lists the steps; one yes runs them in order, each logged as its own request. A message Aegis is asked to send still asks twice on its own card: the plan stops there and carries on only once that card is sent; cancelling it cancels the rest of the plan (#59). The plan also stops, and its remaining steps are logged as cancelled, if the panel closes before a step (#59).

**Follow-ups in context (#49, the owner's request 2026-10-23).** After a command, the panel keeps a `CommandContext` (the owner's words, what Aegis did or proposed, the part of the words naming the thing, and the other matches it found for files and apps). It holds only the owner's words and Aegis's own results, never collected content. It lasts the chat's ten minutes (`Chat.memory`) and is cleared when the owner ends the conversation. `FollowUp` reads "open the other one", "the second one", "the last one", "again", "close it", "show it in Finder" and "do the same for X". `CommandContext.resolve` turns each into a new command, the owner's words with the thing swapped (asked again through the usual path), or a sentence saying why not. A follow-up to something the model picked keeps that provenance, so its replay asks first too (#59). Every resolved command is a new request through `ActionPolicy` and the log. A card still waiting for the last command is cancelled (and logged) when the owner picks another match. "Again" after a chat question stays the chat's own "do that again". "Close it" quits the app Aegis just opened or controlled (new verb `close`, auto like opening: the app asks about unsaved work itself; never Aegis or Finder). One file or tab isn't closed yet.

**AI picks ask first.** A step the model picked is raised to the confirm tier through `ActionOwnerSettings.minimumTier` (settings can only raise). It shows a card with what Aegis worked out ("Open www.bom.gov.au?") and runs on Open or "yes". An address or shortcut name the owner gave goes through at its normal tier.

**Policy changes.** The new domains are `web` and `shortcut`, with the new verb `run`; catalogue entries are in the `app` domain and only `run`. `ActionPolicy` treats an opened website like an opened app (auto). Its own address doesn't count as a URL hazard, because the address is the point (the same for a new Safari tab), but the instruction-like check still applies, including to a note's title or a playlist's name. A shortcut is auto with reason `ownerShortcut`. Aegis can't see inside a shortcut, so its name is checked against the never-list words, and a match is `never` with that category's reason code. The fixed never-list, panel-open rule, hazard raises and codes-only log are unchanged. Text from emails, messages, notifications and web pages still has no path to any of this: only the owner's own panel input is parsed or sent to the model, and the catalogue holds only the owner's shortcut names.

**Network.** Aegis itself makes no new network calls. A website opens in the owner's browser because they asked for it.

## Consequences

- New abilities are added as typed cases with a catalogue line, not as hand-written commands. The model widens the phrasing; it never widens what can run. The model names a file; it never gives a path.
- A shortcut runs with whatever it contains. The owner chose speed over a card for shortcuts they name; the name check catches only obvious never-list shortcuts.
- Command-like requests that nothing handles cost one short model job before the normal answer.
- Volume and dark mode are catalogue entries rather than `ActionPayload.system` edits: they run fixed scripts like the rest of the catalogue, and the owner chose for them to run at once (#45). `.system` keeps ADR-0016's confirm tier for any later setting.
- Review fixes (#59, Codex): the shortcut never-list matches every common form of its words ("Deleting", "Ordered", "Purchases"); a file is checked and opened at its real target, with Finder aliases and symlinks followed and the target held to the same rules (inside the home folder, not hidden, not a program, allowed by the policy); command and message decisions use the panel's real state, so nothing is allowed while it's closed, and Aegis doesn't speak a reply then.
- A plan's one yes covers every step's single confirmation, including steps the model worked out, because each step is on the card the owner approves. Two-confirmation steps keep their own card. New catalogue entries are added the same way: a case, a fixed script, a phrase and a line in the model's catalogue.

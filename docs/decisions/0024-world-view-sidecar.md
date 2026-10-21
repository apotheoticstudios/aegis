# ADR-0024: The World view runs God's Eye View as a local sidecar

**Status:** Accepted (owner's request, 2026-10-19) · **Issue:** #265 · **Design:** DESIGN.md › World view

## Context
DESIGN.md chose God's Eye View (MIT) for the World view: a CesiumJS globe of live public data, run locally only while the view is open. Its data comes through its own Node server (Vite with provider middleware), which also serves its tools at `/mcp` and an embed mode (`?embed=1`).

## Decision
- **Install:** `scripts/world-setup.sh` fetches a pinned commit (`93ea088f`) into `~/Library/Application Support/Aegis/World`, outside the repo and the app bundle. It runs `npm ci --ignore-scripts` (package lock pinned, no install scripts) and `npm run build`. Node.js 24 or 26 is the owner's Homebrew Node for now; bundling Node comes with the setup wizard.
- **Run:** opening the World view starts its server as its own launchd job (`dev.aegis.world`):
  - It binds to 127.0.0.1 only, on port 4173 or a fallback.
  - It isn't a child of Aegis, so it doesn't inherit Aegis's privacy permissions.
  - It gets its own HOME and logs nothing.
  - Closing the window or quitting Aegis boots the job out, ending the server, and the web view's memory goes with the window.
- **Show:** a Aegis window with a WKWebView on a non-persistent data store. For now it shows the app's own UI. Phase 2 moves to embed mode inside the HUD, steered by Aegis's voice through the local `/mcp` tools (the `show_in_gods_eye_view` views).
- **Data:** Aegis gives it nothing personal. Its server and the globe fetch public feeds (USGS, ADS-B, satellites, weather…) and map tiles. This is the World view's allowed network use (AGENTS.md principle 1). No keys are set; the Cesium ion key (3D cities) comes later in settings.

## Consequences
- The World view needs a one-time setup (about 20 s) and Node. Idle RAM is unchanged: nothing runs while it's closed.
- Until phase 2 the full God's Eye View UI is shown, including layers DESIGN.md leaves out of Aegis's integration (public CCTV, licence-plate cameras). Phase 2's embed mode limits layers to situational awareness.
- Updating God's Eye View means moving the pinned commit after a review.

## Amendment (2026-10-19, phases 2 and 3)
- **Steering (phase 2):** the owner's World commands (`WorldCommand` in AegisKit) call the globe's local `/mcp` tools. The suggested view is posted to the embed-mode globe; camera and licence-plate layers are always stripped.
- **In the panel (phase 3):** the panel's WORLD button, or a World command while the panel is open, moves the globe into the panel, which grows to fit. Closing the panel or pressing BRIEF stops the server unless the globe also has its own window.
- **Keys:** Cesium ion (3D cities), AISStream (ships), NASA FIRMS (fires) and TomTom (traffic) are optional.
  - They're stored in the Keychain and set under *World view keys…*. They're passed only as environment to the local server's launchd job; its plist is 0600 and removed once read.
  - The Cesium token is built into the globe's page, so a change triggers one rebuild (`vite build`, its own launchd job) on the next start.
- **The owner's places:** "show my trips" pins upcoming calendar events using EventKit's own coordinates (`CalendarOccurrence.coordinate`, additive), read on the Mac with no geocoding.
  - Pins and labels go only into the local globe page.
  - Map tiles for the framed area are fetched from the imagery provider like any map view.
  - "Show my flight" finds a flight number in the calendar and follows it live, so the callsign (public flight data) goes to public ADS-B feeds through the local server.
  - Home isn't placed yet: that needs coordinates the Mac doesn't hold without an online lookup.

## Amendment (2026-10-19, phase 4)
- **Self-installing:** Aegis bundles `world-setup.sh` and runs it as its own launchd job on the first open, showing each step. It installs into `World/`:
  - Node 24.22.0 LTS from nodejs.org, checked by SHA-256.
  - God's Eye View at the pinned commit from GitHub's archive, checked by SHA-256, or by the commit itself through git if the archive's bytes change.
  - Then `npm ci --ignore-scripts` and the build.
  Homebrew's Node remains only as a fallback, and a newer pin in a Aegis update re-runs the setup.
- **Home:** "set my home here" reads the Mac's location once (Core Location, asked by macOS the first time; hardened-runtime location entitlement). The point is saved in Aegis's folder (`home.json`, 0600).
  - "Show my home" pins it on the local globe only.
  - "Flights / earthquakes / weather near home" send home rounded to 0.1° (about 10 km) with a 50 km radius, so the region, never the house.
- **In the brief:** while the panel is open, at most every 30 minutes, and switchable under *World view settings…*:
  - today's weather at home from Open-Meteo (home rounded to 0.1°);
  - today's calendar flight from adsb.lol (by callsign only).
  They show in a WORLD line and are read with the brief. AegisCore stays offline: the panel fetches them.

## Amendment (2026-10-20, #295, #296)

The owner chose God's Eye View's own interface, full screen, over Aegis's embed-mode globe. The World view opens in its own full-screen window; the panel floats over it. God's Eye View accepts posted views only in embed mode, so Aegis now applies its views through the page's own actions (a port of God's Eye View's `applyView`, MIT). God's Eye View's own layer controls, including public CCTV and licence-plate cameras, are the owner's to use in its interface; Aegis's commands still never turn those on. God's Eye View keeps its own settings in this Mac's web storage (`WKWebsiteDataStore.default()`), instead of a fresh store each time, so its welcome and choices are remembered. For anything beyond Aegis's own commands, the local model picks from a catalogue of God's Eye View's page actions (#296); Aegis validates the plan and runs it through the page's runner.

## Amendment (2026-10-20, #299)

The owner moved the globe back inside the Aegis panel: God's Eye View's own interface fills the panel (which grows to the screen) under a ◀ AEGIS strip, with Aegis's Ask bar along the bottom; no separate window. Views still go through the page's own actions; the globe and its server stop when the panel closes.

## Amendment (2026-10-20, #311)

Owner's decision: Aegis may use every God's Eye View layer and action, including public CCTV (`control_cctv`, `cctv`) and licence-plate reader locations (`alpr-cameras`); the earlier rule that Aegis never turns them on is withdrawn. Aegis is also God's Eye View's voice: an injected page script sends presses of `#gev-voice-button` to Aegis (a `aegis` message handler accepting only "talk" from the main frame, only while the globe shows), so voice works through Aegis's local pipeline instead of God's Eye View's OpenAI realtime session; questions and answers are written into God's Eye View's voice card. The owner's own places are still never sent to God's Eye View's online place search.

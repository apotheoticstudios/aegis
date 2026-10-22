# ADR-0029: The Project: Aegis design system

- **Status:** accepted
- **Date:** 2026-10-21
- **Proposed by:** Claude · **Approved by:** the owner (2026-10-21: "use the exact layout shown in the design artefact … build it and make it work with Aegis") · **Issue:** #8

## Context
The owner chose to rebuild the interface around the **Project: Aegis design system**, a design-system artifact in the owner's claude.ai account: colour tokens for five themes, five typefaces, about thirty components, a motion system, character art and five worked screens (HOME, SYSTEM, COMMS, CHAT, LOGS) plus a boot screen. It replaces concept A (#292): three columns of frosted glass, cyan and amber, system monospace. The app had no shared tokens; colours, fonts and spacing were literals in each view.

## Options considered
1. Restyle concept A's colours only. Rejected: the owner asked for the design's own layout.
2. Run the design system's web components in a web view. Rejected: a second UI stack, more memory while open, and collected message text rendered next to a script bridge.
3. Native SwiftUI: the tokens in one place and the components and screens rebuilt from the design system's own code. **Chosen.**

## Decision
- **Tokens in one place**, `Apps/AegisApp/Sources/Design/`: `HUDTokens.swift` (every colour of all five themes, copied exactly from the design's `tokens.json`; space, chamfers, strokes, timing), `HUDType.swift` (the type scale). Views name tokens (`HUD.primary`, `.hudType(.label)`), never literal colours or system fonts. The theme travels in the SwiftUI environment; **Arc is the default** (owner's choice). Tests hold every theme to the design's own contrast rules (text 4.5:1, edges 3:1).
- **Components** ported from the design's code: the shell with circuit links (or curved wires) from a hub, menu tabs, inset sections, glass panels, plates, chips, tags, readouts, segment and character meters, sparklines, the particle field, ring gauges, notification, log and chat rows, the terminal input, character art (radar, eye, helix, wave, anatomical heart, from the design's generators) and the AEGIS banner, cut at run time from the bundled Xirod face so any assistant name works.
- **The five screens follow the design's worked screens exactly**, filled with Aegis's own data. Where the design shows something Aegis has no source for, the slot shows the nearest real thing and says so: no home control yet, so HOME's home panel shows today's calendar; no iPhone link, so COMMS shows it "Not linked"; no audio level, so CHAT's voice panel shows the voice's state with the wave. Nothing is invented.
- **New data, counts only.**
  - An additive request, `CoreRequest.activity(hours:)` (at most 24), answered by AegisCore with `HourlyActivity`: how many events it collected in each hour, by source. Counts only, never content; it reads the store the brief already reads. It feeds HOME's 24-hour field and inbox bars, COMMS's notifications per hour and LOGS's total.
  - The SYSTEM screen and HOME's machine panels read the Mac's own counters (processor per core, memory, swap, disk, network and disk throughput, the graphics processor's utilisation from IOKit's public registry, thermal state, load, uptime, and the busiest processes with Aegis's own first). They are sampled once a second **only while one of those screens is open**, kept in memory, never written or logged, and nothing leaves the Mac.
- **Fonts** are bundled in Aegis.app and registered for Aegis's own process only, never installed on the Mac:
  - Xirod 3.001 (Typodermic, **CC0 1.0**, public domain);
  - Chakra Petch SemiBold, Kode Mono Regular and SemiBold, and VT323 (**SIL OFL 1.1**): the design system's Google Fonts WOFF2 files;
  - Share Tech Mono (**SIL OFL 1.1**, Reserved Font Name "Share"): the unmodified original from google/fonts (commit `1b86e1e716445daccc346253911955073b0d254a`), because the design's copy was a subset (219 of 268 glyphs), and a modified font can't keep a reserved name.
  - Only the faces the type styles use ship, about 110 KB. Each OFL family's licence sits beside it, in the repo and in the app. OFL-1.1 and CC0-1.0 are accepted **for font assets only**; code stays MIT or Apache-2.0.
- **The emblem** from the design's logo kit (the owner's own mark) ships as a 136-pixel PNG for the top bar, and in characters (`emblem.txt`) for the boot screen.
- **Motion** follows the design's Motion.md (`HUDMotion.swift`): each time a screen shows in the open panel (opening, or a tab switch), it builds itself in about 2 s (the shell traces on and opens, the tabs and heads flicker on, sections draw their rules in pairs, meters fill, rows type, values scramble, art resolves, links draw out from the hub). Glows light only once their part has settled. Geometry glides on the ease curves, text steps. The live tag breathes and the caret blinks. Nothing moves while the panel is closed, and Reduce Motion turns it all off.
- **Still for now:** glass has no backdrop blur (behind it is only the void and a soft wash).

## Consequences
- Every later step (motion, the settings windows, a theme picker, the menu-bar drop-down, the app icon) builds on these tokens and components.
- The panel opens on HOME. A question in progress or the voice listening switches to CHAT; ⌘1 to ⌘5 switch screens.
- Characters the fonts lack (box drawing, ▸ ▾, ⌥ ⏎, the block shades) fall back to the system font; block banners are set in the system monospaced face on purpose.
- WOFF2 registration is checked on macOS 26 and later (CI and the owner's Mac). On older systems the panel would fall back to system fonts; nothing breaks.
- The SYSTEM screen lists the Mac's busiest processes by name, like Activity Monitor, while it is open.
- The contract change is additive: every `CoreService` implementation (AegisCore's engine, the sample, the test fakes) answers `activity`.

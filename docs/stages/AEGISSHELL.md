# AegisShell: build plan

What it is: [`DESIGN.md` › AegisShell](../design/DESIGN.md#aegisshell-os-style-shell). A shell over macOS that makes the Mac feel like Aegis's own operating environment while it's engaged, and leaves no trace when it isn't. Visuals: [`docs/design/aegisshell-brief.md`](../design/aegisshell-brief.md).

Status: stage 1 built (engage and disengage, Aegis's menu bar item, the desktop's frame and core; ADR-0033). The design system's AegisShell cards are the exact design. Each stage below is one issue and one PR (or a few small ones), merged only when its acceptance checks pass.

## Ground rules (from AGENTS.md and the spec)

- **On demand only.** Off at login. Nothing AegisShell adds uses CPU, GPU or RAM while it's disengaged.
- **Always an exit.** The disengage hotkey and the menu bar icon restore normal macOS even if something in AegisShell fails. Disengaging restores everything it changed: Dock, menu bar, wallpaper, window positions.
- **No SIP or private APIs.** Public APIs only; macOS asks permission per feature (Accessibility for window management, Automation for apps).
- **System settings only through save-and-restore.** Any macOS setting AegisShell changes (for example Dock auto-hide) is saved first and put back on disengage, crash or quit. This is the one place AGENTS.md allows Aegis to change system settings.
- **Silent.** No sounds unless the owner turns interface sounds on.
- **Privacy on screen.** Widgets hide names and content during screen sharing, while the Mac is locked, and when "hide details" is on.
- **Actions follow the safety system.** Anything a widget or the launcher does goes through ActionPolicy (tiers, never-list, action log), exactly like commands in the panel.
- **Performance.** The live desktop freezes to a still frame when covered or when the Mac is busy (it keeps moving on battery, owner's choice); widgets pause when hidden. Animated glows are flattened into one layer (the window server lesson from the SYSTEM screen).

## Stage 0 — Feasibility spike (answered in ADR-0033)

The design keeps macOS's own menu bar (owner's choice, 2026-10-27), so the menu bar questions fall away. The Dock hides through its own auto-hide setting, saved and restored. The desktop is a panel at Finder's icon level plus one on every Space. Window frames wait for window layouts. Cost on the owner's Mac is still to measure (stage 3).

A throwaway prototype in `Prototype/` that answers, on the owner's Mac (macOS 26, notched display):

| Question | Why it matters | Likely answer to confirm |
| --- | --- | --- |
| Can Aegis hide the Dock and menu bar while *other* apps are frontmost? | `NSApplication.presentationOptions` only applies while Aegis itself is active. | Save and set Dock auto-hide and menu bar auto-hide (System Settings values), restore on disengage. |
| Can a window sit on the desktop layer, under all app windows, and stay interactive? | The live desktop and custom widgets. | A borderless window at desktop level (`kCGDesktopWindowLevel`), visible on every Space; check clicks and drags work and Mission Control/Stage Manager behave. |
| Can an Aegis top bar replace the menu bar area without fighting it? | The notch and the hidden menu bar sliding over the top bar. | A borderless bar window at status level below the notch area; menu bar appears on hover over it. |
| Window management by command | "Mail left, calendar right". | Accessibility API (AXUIElement) moves and resizes other apps' windows after the owner grants Accessibility. |
| Multiple displays, full-screen apps, Spaces | It must not break normal use. | Decide per display; step aside for full-screen apps. |
| Cost while engaged | Budget. | Measure CPU, GPU and window server load with everything showing; target under 5% CPU at rest. |

Output: `docs/stages/AEGISSHELL-SPIKE.md` with the answers (numbers only, no personal data) and an ADR (`docs/decisions/`) for the approach and every macOS setting AegisShell will touch.

## Stage 1 — Engage and disengage

- Engage from a dedicated hotkey, the menu bar ("Engage AegisShell"), a panel button and "Aegis, engage"; disengage the same ways plus "Aegis, stand down".
- Save state on engage (Dock and menu bar settings, wallpaper, window frames) to a file in Aegis's folder; restore on disengage, on quit, and on the next launch after a crash.
- The engage/disengage transition from the design brief.
- **Done when:** engaging and disengaging 20 times in a row leaves macOS exactly as before (checked automatically: settings and window frames compared), crash recovery restores state, and nothing AegisShell added runs while disengaged.
- **Built (2026-10-27):** ⌃⌥A, the menu, Exit and "engage" / "stand down"; the Dock's auto-hide saved, restored on disengage, quit and after a crash (20 cycles and a crash tested with a fake Dock); the design's 1.9 s engage and 1.0 s disengage (ShellMotion, tested), Reduce Motion's crossfade; the desktop's wash, traced frame and the ReactorCore in today's ScheduleArc with Aegis's line (counts and times only). Panel button and the owner's first real run to come.

## Stage 2 — Aegis's menu bar item (replaces the top bar)

- The design's ShellMenuExtra in macOS's own menu bar: the hexagon (filled and glowing), the workspace, the status word, an urgent count and Exit; and ShellMenu, its glass menu.
- **Built (2026-10-27):** the item, Exit and the menu with the panel, talk and Disengage. Workspaces, the launcher, arranging, window layouts and the privacy switches join the menu with their stages.

## Stage 3 — Live HUD desktop

- The desktop-level layer: reactor, event stream, today's schedule, home status (when Home control exists), in the active theme.
- Freezes to a still frame when covered by windows or when the Mac is busy (not on battery, owner's choice); resumes when visible.
- **Done when:** it renders under all windows on every Space, freezes as specified (measured), and window server load stays within 5 points of macOS's own wallpaper.
- **Built (2026-10-27):** the readings drawn into the scene, as the design's ShellDesktop.
  - **Status** is pinned to the core: the urgent count, the top item, Open in panel. **Next up** is pinned to its event on the arc, with a sand glass and the minutes to go.
  - The people **waiting** sit on an orbit, coloured by how long they've waited. The **system** shows as disk and memory arcs, with a turning tick ring and a callout when a source needs a fix.
  - The brief's **Play** and item count sit under the core, the **ask line** on the ground, and the **wireframe floor** under it all.
  - **Still frame:** when the Mac is hot, under Reduce Motion, by choice, or while every display's desktop is covered. The reactor, the art, the rings and the pings stop, and a line says why.
  - **The stream** (2026-10-27, with #78's recent events): one line per event at the top left, fading downwards, the urgent one marked; kinds only with details hidden.
  - **The world** rises out of the corner (the globe, home pinned when set), with today's weather at home above it (storm or sun art; the brief's forecast, home rounded to about 10 km, only with the World lines switched on). **Home** shows the floor plan marked "not set up" until Home control exists. Matrix's ground is falling code (#77's shapes, ported by Codex).
  - **Something urgent** (2026-10-28, the design's ShellDesktopUrgent): while an urgent item is new since the panel was last opened (the menu bar's glow), one line opens under the ask line between critical hairlines, with Open and Later; Later sets it aside until another item is first. The menu bar item adds the hidden mark while details are hidden, and the menu's urgent row names the top item when they aren't.
  - **Still to come:** the tracked flight on the globe, Home control's real states, and measuring the cost on the owner's Mac.

## Stage 4 — Custom desktop widgets

- The widget set from the spec: Status core, Waiting on you, Next up, Brief, World, Ask, System (Home once Home control exists).
- Place, move, resize and remove; layouts saved per workspace.
- "Hide details" per widget; content hidden during screen sharing and when locked.
- **Done when:** every widget works with synthetic data in tests, privacy hiding is tested, and hidden widgets do no work.
- **Started (2026-10-27):** in the new design the widgets are the readings drawn round the core (stage 3). **Hide details** (counts and kinds, never names or words) is on by default until screen sharing can be detected; the owner turns it off in Aegis's menu, beside **Hold the desktop still**. The desktop windows are also left out of screen capture where macOS honours it.

## Stage 5 — Launcher

- In AegisShell, ⌥Space opens the launcher style of the panel: one bar to open apps, files and settings, ask, and run commands (reusing the general command system, ADR-0031).
- **Done when:** the top results match what Spotlight would open for app and file names, and every action goes through ActionPolicy.
- **Built (2026-10-27):** the design's Launcher over a dimmed desktop, a third of the way down: apps by name, files by name (Spotlight, names only), System Settings pages, a command row when the words read as one, and Ask Aegis; suggestions when nothing is typed; no results offers to ask instead. ↑↓, ⏎ (⌘⏎ asks), esc. Apps, files and settings open through ActionPolicy (`PanelModel.launch`); commands and questions go to the panel. ⌥Space opens it while engaged, as do the ask line on the desktop and Aegis's menu. Still to come: the listening state inside the launcher and the ConfirmCard in place of results.

## Stage 6 — Window management and workspaces

- Window layouts by command ("Mail left, calendar right", "focus on Xcode"), saved layouts, and workspaces (Work, Focus, Evening, Movie) that switch layout, widgets and Focus mode (home scenes once Home control exists).
- **Done when:** layouts apply and restore reliably across 3 common apps, and workspaces switch in under a second.
- **Built (2026-10-27):** window layouts by command while engaged. "Mail left, calendar right", "Xcode on the left two thirds, Terminal on the right third", "focus on Xcode", "centre Notes", "split Safari and Mail" (#83, parsed in AegisKit by Codex). An app that isn't open is opened first. Each window moves with the Accessibility API, logged through ActionPolicy, and every moved window goes back on disengage. Words only count as a layout when every name is an app on this Mac. Still to come: the zones and gliding animation, and saved layouts.
- **Workspaces (2026-10-27):** Work, Focus, Evening and Movie, from the menu's switcher, ⌃1–4 while engaged (⌃⌥1–4 when another app holds any of them), or "focus mode", "switch to evening", "movie time", "back to work". Each has its accent (the design's `workspace-*` tokens, per theme), its wash and its scene. Focus is a tunnel behind a smaller core, with next up and the ask line. Evening has a planet, a night skyline, home and the world. Movie is nearly black: a black hole, a small core and one line. The switch crossfades: the readings go, then the new scene draws in (200 ms under Reduce Motion). Still to come: workspaces that change Focus mode, layouts or home scenes, and the held-notifications callout.

## Stage 7 — Overlays and polish

- Talk to Aegis and see its HUD over any app; optional interface sounds (off by default); themed wallpaper.
- Optional auto-engage on a dedicated hub Mac (off by default).

## Dependencies and order

Stage 0 decides feasibility and goes first. Stages 1–2 are the minimum usable AegisShell. Home widgets and workspace home scenes wait for Home control. The design brief should be designed before Stage 2 starts; Stage 1's transition can use a placeholder.

## Risks

| Risk | Mitigation |
| --- | --- |
| macOS changes how Dock/menu bar hiding or desktop-level windows behave | Spike first; keep every change behind save-and-restore; the exit hotkey works even if the shell fails |
| Window server load from a full-screen animated desktop | Flatten glows, freeze when covered or busy, measure every stage |
| Accessibility permission feels heavy | Window management is optional; everything else works without it |
| Leaving the Mac changed after a crash | State file restored at next launch; tested |
| Distribution | A shell like this can't ship on the Mac App Store; direct download, signed and notarized (already the plan) |

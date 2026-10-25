# AegisShell: build plan

What it is: [`DESIGN.md` › AegisShell](../design/DESIGN.md#aegisshell-os-style-shell). A shell over macOS that makes the Mac feel like Aegis's own operating environment while it's engaged, and leaves no trace when it isn't. Visuals: [`docs/design/aegisshell-brief.md`](../design/aegisshell-brief.md).

Status: planned, nothing built. Each stage below is one issue and one PR (or a few small ones), merged only when its acceptance checks pass.

## Ground rules (from AGENTS.md and the spec)

- **On demand only.** Off at login. Nothing AegisShell adds uses CPU, GPU or RAM while it's disengaged.
- **Always an exit.** The disengage hotkey and the menu bar icon restore normal macOS even if something in AegisShell fails. Disengaging restores everything it changed: Dock, menu bar, wallpaper, window positions.
- **No SIP or private APIs.** Public APIs only; macOS asks permission per feature (Accessibility for window management, Automation for apps).
- **System settings only through save-and-restore.** Any macOS setting AegisShell changes (for example Dock auto-hide) is saved first and put back on disengage, crash or quit. This is the one place AGENTS.md allows Aegis to change system settings.
- **Silent.** No sounds unless the owner turns interface sounds on.
- **Privacy on screen.** Widgets hide names and content during screen sharing, while the Mac is locked, and when "hide details" is on.
- **Actions follow the safety system.** Anything a widget or the launcher does goes through ActionPolicy (tiers, never-list, action log), exactly like commands in the panel.
- **Performance.** The live desktop freezes to a still frame when covered, on battery or when the Mac is busy; widgets pause when hidden. Animated glows are flattened into one layer (the window server lesson from the SYSTEM screen).

## Stage 0 — Feasibility spike (before anything is designed in detail)

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

## Stage 2 — Aegis top bar

- Replaces the hidden menu bar: emblem, assistant name, clock, status word, quick toggles (Do Not Disturb/Focus, volume, Wi-Fi status, battery), the exit control.
- Works with the notch and multiple displays.
- **Done when:** the bar shows on each display, the macOS menu bar still appears on hover, and the bar costs under 1% CPU at rest.

## Stage 3 — Live HUD desktop

- The desktop-level layer: reactor, event stream, today's schedule, home status (when Home control exists), in the active theme.
- Freezes to a still frame when covered by windows, on battery, or when the Mac is busy; resumes when visible.
- **Done when:** it renders under all windows on every Space, freezes as specified (measured), and window server load stays within 5 points of macOS's own wallpaper.

## Stage 4 — Custom desktop widgets

- The widget set from the spec: Status core, Waiting on you, Next up, Brief, World, Ask, System (Home once Home control exists).
- Place, move, resize and remove; layouts saved per workspace.
- "Hide details" per widget; content hidden during screen sharing and when locked.
- **Done when:** every widget works with synthetic data in tests, privacy hiding is tested, and hidden widgets do no work.

## Stage 5 — Launcher

- In AegisShell, ⌥Space opens the launcher style of the panel: one bar to open apps, files and settings, ask, and run commands (reusing the general command system, ADR-0031).
- **Done when:** the top results match what Spotlight would open for app and file names, and every action goes through ActionPolicy.

## Stage 6 — Window management and workspaces

- Window layouts by command ("Mail left, calendar right", "focus on Xcode"), saved layouts, and workspaces (Work, Focus, Evening, Movie) that switch layout, widgets and Focus mode (home scenes once Home control exists).
- **Done when:** layouts apply and restore reliably across 3 common apps, and workspaces switch in under a second.

## Stage 7 — Overlays and polish

- Talk to Aegis and see its HUD over any app; optional interface sounds (off by default); themed wallpaper.
- Optional auto-engage on a dedicated hub Mac (off by default).

## Dependencies and order

Stage 0 decides feasibility and goes first. Stages 1–2 are the minimum usable AegisShell. Home widgets and workspace home scenes wait for Home control. The design brief should be designed before Stage 2 starts; Stage 1's transition can use a placeholder.

## Risks

| Risk | Mitigation |
| --- | --- |
| macOS changes how Dock/menu bar hiding or desktop-level windows behave | Spike first; keep every change behind save-and-restore; the exit hotkey works even if the shell fails |
| Window server load from a full-screen animated desktop | Flatten glows, freeze when covered or on battery, measure every stage |
| Accessibility permission feels heavy | Window management is optional; everything else works without it |
| Leaving the Mac changed after a crash | State file restored at next launch; tested |
| Distribution | A shell like this can't ship on the Mac App Store; direct download, signed and notarized (already the plan) |

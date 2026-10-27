# ADR-0033: How AegisShell sits on macOS

- **Status:** Accepted (owner's request, 2026-10-27)
- **Design:** the design system's AegisShell cards (ShellEngage, ShellMenuBar, ShellDesktop); `docs/stages/AEGISSHELL.md`

## Context

AegisShell makes the Mac feel like Aegis's own environment while it's engaged and leaves no trace when it isn't. The design system settled what it looks like: macOS keeps its own menu bar (the owner confirmed this on 2026-10-27), the Dock drops away, and the desktop becomes a live HUD under every window. AGENTS.md allows Aegis to change system settings only through AegisShell's save-and-restore, with no private APIs and SIP left alone.

## Decision

- **Menu bar:** macOS's own, untouched. While engaged, Aegis's everyday menu bar icon gives way to the design's ShellMenuExtra: two ordinary status items, the hexagon with the workspace, status and an urgent count (it opens ShellMenu, Aegis's own glass panel), and Exit. Nothing hides or replaces the menu bar, so the notch, Control Centre and the front app's menus behave as always.
- **Dock:** its auto-hide setting, the only macOS setting AegisShell changes so far.
  - The current value is read from the Dock's preferences (`CFPreferencesCopyAppValue`, read only).
  - It's saved to `~/Library/Application Support/Aegis/shell-state.json` before anything changes, then set through System Events (`dock preferences`), which animates the Dock like System Settings does. This needs the Automation permission Aegis already asks for, and its usage text now says so.
  - It's put back on disengage, at quit, and at the next launch after a crash. The file goes only once the restore worked.
  - An owner who already hides the Dock sees no change.
- **Desktop:** one borderless, non-activating panel per display at Finder's desktop-icon level plus one. That's below every app window and above the hidden icons, on every Space, stationary in Mission Control and out of the window cycle. It takes clicks, so nothing reaches the hidden icons, and never activates Aegis. The wallpaper isn't changed: the desktop covers it, so dynamic and shuffled wallpapers can't be lost.
- **Ways in and out:** ⌃⌥A (Carbon `RegisterEventHotKey`, no Accessibility needed), the menu, Exit and the menu's Disengage, and the owner's words ("engage", "stand down"; `ShellCommand` in AegisKit). The shortcut and Exit always work, whatever the desktop is doing.
- **Off means off:** no windows, items, timers or animation while disengaged. Character art runs only while the panel, the wizard or the shell shows (`HUDPresence.shell`).

## Consequences

- The design's engage transition and disengage play exactly as specified (ShellMotion, tested). Reduce Motion gets one 300 ms crossfade, and the Dock follows macOS's own Reduce Motion behaviour.
- The desktop shows names only once "hide details" and screen-sharing detection exist (stage 4). Until then the line under the core and the schedule arc use counts, times and "Event".
- Not decided yet:
  - The still frame on battery or when busy (stage 3). The reactor already pauses when its window is fully covered.
  - Window frames: nothing moves windows until window layouts (stage 6), so nothing needs restoring yet.
  - Multiple displays per workspace.

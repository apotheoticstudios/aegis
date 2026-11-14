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

## Amendment (2026-10-27, stage 3)

- **Hide details is on by default.** macOS offers no public way to know the screen is being shared, so the desktop shows counts and kinds ("Contact 1", "Event", "From a contact") until the owner turns details on in Aegis's menu. The setting is kept across launches. The desktop windows also set `sharingType = .none`, which keeps them out of capture where macOS honours it.
- **Still frame:** the desktop holds still on battery (IOKit power sources), when the Mac is hot (thermal state serious or critical), under Reduce Motion, by the owner's choice, or while every display's desktop window is covered (window occlusion). It's checked every 10 seconds and on occlusion changes, and resumes by itself.
- **Readings:** read from AegisCore every five minutes while engaged (the brief, the people waiting, source health, today's schedule). The system figures come from one process sample at the same moment. Nothing is read while disengaged.

## Amendment (2026-10-27, stages 5 and 6: the launcher and window layouts)

- **AegisShell counts as the panel being open** for the action safety system. The policy only lets actions run while the owner is present, and while engaged the shell is Aegis's interface on screen: the launcher's apps, files and settings, and window layouts, come from the owner's own typing or voice there. Everything else about the tiers, the never-list and the action log is unchanged.
- **Arranging an app's windows runs at once** (`ActionPayload.app(…, verb: .move)` is `auto`). It moves only windows, which AegisShell puts back on disengage. Moving files still asks. Window moves are logged one per app (`ShellWindows`), and need the Accessibility permission, which macOS asks for the first time.

## Amendment (2026-10-27, the owner's choices after trying it)

- **The desktop covers macOS's desktop widgets:** its windows sit just under every app's windows (`NSWindow.Level.normal - 1`), above Finder's icons and the widgets. Before this they sat at the desktop-icon level, and the widgets showed through.
- **No frame:** the design's frame traced round the screen, and its corner brackets, are left out.
- **It keeps moving on battery:** the still frame is for a hot Mac, Reduce Motion, Hold still and being covered.

## Amendment (2026-10-28): voice over any app

While AegisShell is engaged with details showing, Talk to Aegis (its key, the menu, the ask line's mic) shows the design's voice overlay centred under the menu bar instead of opening the panel. It runs the panel's own voice turn and counts as an open Aegis surface for the silent rule: Aegis speaks only while it shows, it fades 3 s after the answer, disengaging silences it, and anything needing a confirmation (or voice that can't be used) hands over to the panel. The wake listener treats it as the open panel. With details hidden, Talk opens the panel as before, because the overlay would show your data over whatever is on screen. "Hey Aegis" still opens the panel.

## Amendment (2026-11-12): AegisShell's bar over the left of the menu bar

The owner asked for AegisShell's controls to replace the left of the menu bar, where the Apple menu and the front app's menus sit, while it's engaged (#175). This replaces the two status items on the right.

- **One borderless, non-activating panel per menu bar**, just above the menu bar's level (`NSWindow.Level.statusBar`) and below its menus. It runs from the display's left edge to the notch (`NSScreen.auxiliaryTopLeftArea`), or halfway across a display without one, as tall as the menu bar. Public APIs only: the menu bar itself isn't hidden, moved or changed, so Control Centre, the status items and the notch behave as always.
- **The front app's menus are covered while engaged** and reached by their shortcuts (owner's choice; no button to show them). They return the moment AegisShell disengages.
- **It shows only where a menu bar takes room.** It skips a menu bar that hides itself and a second display without its own, so it never covers a window's buttons. It stays out of full-screen Spaces, where the app keeps its own menu bar. It follows display and Space changes.
- **Contents:** the hexagon with the status word, the hidden mark and an urgent count (it opens ShellMenu), the four workspaces, Launcher, Talk and Exit, in the menu bar's own type. It is drawn on the void, so it melts into the desktop behind the see-through menu bar, and it arrives and leaves with the desktop's wash. The desktop covers the strip under the menu bar too, so the whole bar is dark (owner's choice, 2026-11-13). macOS colours its own menu bar items for the wallpaper, not for the windows behind them: over a dark or mid wallpaper they're light and read on the void, over a light one they turn dark and are hard to read. Changing the wallpaper to fix that was tried (#179–#183) and removed: macOS 27's public API reports a placeholder (`DefaultDesktop.heic`) for a modern wallpaper, so it couldn't be put back. Still silent: visual only, and nothing while disengaged.
- **The way out** is now the bar's Exit, ShellMenu's Disengage, ⌃⌥A and "stand down". On the narrowest menu bar the bar folds to the hexagon and Exit, so Exit is never cut off. Aegis's everyday icon now stays in the menu bar while engaged (under the bar where the bar shows), so where no bar shows at all (a menu bar that hides itself) it is the way out, with Disengage in its menu.

## Amendment (2026-11-13): AegisShell's bar covers the whole menu bar

macOS colours its own menu bar items (status items, the clock) for the wallpaper alone, so over a light wallpaper they turned black and vanished beside the dark bar. No public API makes them white, and changing the wallpaper couldn't put the owner's own back (above). The owner chose to replace the whole bar (#188), accepting that macOS's own items, Control Centre and other apps' status items can't be clicked while engaged.

- **The bar spans the whole menu bar**, one level above the status bar (`NSWindow.Level.statusBar + 1`, where macOS's own items sit) and still under its menus. Nothing is drawn behind the notch: the left controls fit `auxiliaryTopLeftArea`, the right side `auxiliaryTopRightArea` (each half of a display without a notch). The rules for where it shows are unchanged.
- **Aegis's own right side**, in white: the network as a kind (Wi-Fi, wired, connected or offline; from `NWPathMonitor`, which sends nothing and never reads the network's name), the battery (level, charging, on power; IOKit power sources, updated by macOS's power-source notice) and the date and time in the Mac's own format. A low battery off the charger fills red with its number beside it.
- **Clicks:** the network and the battery open their System Settings pages through the action safety system, as the launcher does (`.settingsPage`, which only opens a page); the clock opens the panel.
- **Watched only while engaged:** the path monitor and the power notice start with the bar and stop on disengage.
- **Additions (2026-11-14, #188):** the right side also shows the volume (the default output's level and mute, watched through Core Audio while engaged; it opens Sound settings) and a privacy switch for Hide details, which replaces the hidden mark beside the hexagon. The battery's tooltip gives the time left or to full. The bar's controls follow the transition's clock rather than waiting for the Dock and the first readings, and the hexagon's menu takes the keyboard (Tab, esc) without activating Aegis.

# AegisShell: visual design brief

For: the Project: Aegis design system (the same system the HUD panel uses, ADR-0029). Hand this brief to it to design AegisShell's visuals.
What AegisShell is: [`DESIGN.md` › AegisShell](DESIGN.md#aegisshell-os-style-shell). Build plan: [`docs/stages/AEGISSHELL.md`](../stages/AEGISSHELL.md).

## The idea in one line

While engaged, the whole Mac looks like Aegis's own operating environment, a sci-fi HUD over macOS, and the moment it's dismissed, normal macOS returns untouched.

## Use the existing design system, don't start over

Every surface below uses the Project: Aegis design system as it stands:

- **Five themes, one signal.** Arc (default, electric blue), Automaton, Phosphor, Redline, Matrix. Every surface must work in all five. Primary means live; only live things glow; a state colour always comes with its word.
- **Type.** Xirod for display and the name; Chakra Petch for labels; Kode Mono for sentences; Share Tech Mono for numbers and codes; VT323 for the pixel voice. Set small, like a terminal.
- **Edges.** Nothing rounded: square corners or 45° cuts. Hairlines for structure, 2-point lines for meaning. Glass panels over the void, one soft wash behind the centre.
- **Character art.** Banners, shapes and meters from the density ramp ` .:-=+*#%@`, moving at 12 frames a second only when visible.
- **Motion.** The panel's build-on (frame traces on, sections arrive in pairs, rows type, numbers settle, art resolves out of noise, glows light as parts settle). Only live things move afterwards.
- **Reactor.** The existing reactor core is Aegis's heart; reuse it.

## Real-world constraints the designs must respect

- **Displays.** A 14–16" MacBook with a notch (about 1470 × 956 points) is the primary target; also show a 27" external display (2560 × 1440) and a two-display setup.
- **The notch.** Nothing important can sit behind the camera notch at the top centre.
- **Other apps stay theirs.** AegisShell sits behind and around ordinary app windows (Safari, Mail, Xcode). It can't restyle the inside of their windows. Show the desktop both empty and with 2–3 normal app windows open over it.
- **macOS still appears sometimes.** The real menu bar slides down when the pointer hits the top edge; system pop-ups (passwords, permissions) and the login screen stay macOS. Designs should look intentional next to them.
- **Readable over time.** People work in this for hours: the live desktop must be calm, low-contrast enough not to distract, and have a static version.
- **Performance.** Prefer effects that can freeze to a still frame. Avoid many separately animated glowing layers; glows should be able to flatten into one layer.
- **Privacy states.** Every widget needs a "hidden details" version (counts instead of names) used during screen sharing, when locked, or by choice.
- **Accessibility.** Contrast that passes WCAG AA for text in every theme; a Reduce Motion version of each animation; status never shown by colour alone.

## Surfaces to design

### 1. Engage and disengage transition
- From normal macOS to AegisShell (about 1.5–2 s): the Dock and menu bar recede, the frame traces on around the screen, the live desktop resolves out of noise, the top bar and widgets build on.
- The reverse on disengage (faster, about 1 s).
- A Reduce Motion version (a simple fade).

### 2. Aegis top bar
- Replaces the menu bar while engaged, across the full width, below and around the notch.
- Contents: emblem and assistant name (left), the active workspace, the clock and date, the status word (ONLINE, THINKING, SPEAKING, LISTENING), quick toggles (Focus, volume, Wi-Fi, battery), and an always-visible exit control (right).
- States: normal, something urgent waiting, listening, on battery, screen sharing (hidden details).
- How it coexists with the real macOS menu bar when that slides down over it.

### 3. Live HUD desktop (the wallpaper layer)
- Full-screen, beneath all windows: the reactor, a calm event stream, today's schedule arc, and a home status strip (placeholder until Home control exists).
- Variants: idle, something urgent, quiet hours (night), the still frame used when frozen.
- One composition per theme, at both display sizes, and with app windows covering most of it.

### 4. Launcher (⌥Space in AegisShell)
- A single command bar in the HUD style: type or speak; results for apps, files, settings, commands ("run the Work shortcut") and questions.
- States: empty with suggestions, typing with mixed results, a command needing confirmation (the existing confirmation card style), listening by voice, no results.

### 5. Custom desktop widgets
Design each at small, medium and large sizes, with a "hidden details" state and an empty state:

| Widget | Shows | Controls |
| --- | --- | --- |
| Status core | Urgent count, top item, a mini reactor | Tap to open in the panel |
| Waiting on you | Who is waiting and for how long | Reply (opens a drafted reply) |
| Next up | Next event and a countdown | Join, open location |
| Brief | Today's headline | Play aloud |
| World | Weather front, a tracked flight | Open the World view |
| Ask | A mini command line | Type or speak |
| System | Storage, memory, sources' health | Open the fix when something broke |
| Home (later) | Doors, garage, lights, temperature | Light and scene toggles; locks and garage open a confirmation |

Also: how widgets look while being moved, resized and arranged (a placement grid and guides).

### 6. Workspaces
- A switcher (from the top bar and by voice) for Work, Focus, Evening and Movie, each with its own accent, widget set and wallpaper mood.
- A short transition between workspaces.

### 7. Window management overlay
- What shows when the owner says "Mail left, calendar right": target zones previewed on screen, then the windows moving into place; a saved-layout picker.

### 8. Voice and HUD overlay over any app
- A compact listening/answer overlay that floats over whatever app is in front: live transcription, "thinking…", the answer typing as it's spoken (as CHAT does now).

## Deliverables

1. The eight surfaces above, in Arc at the MacBook size, with key states.
2. The live desktop and top bar in all five themes.
3. The external-display and two-display layouts for the top bar and live desktop.
4. Hidden-details and Reduce Motion versions where listed.
5. Motion notes for the transitions and build-ons (durations, easing, order), in the design system's existing motion terms.
6. Any new tokens or components the design needs, added to the design system rather than one-off styles.

## Out of scope for this brief

The login screen, macOS system pop-ups, System Settings, and the insides of other apps' windows: AegisShell can't change these.

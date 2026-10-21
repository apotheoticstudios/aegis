# Accessibility probe (Stage 0, issue #10)

Answers the backup-route question: **can macOS's Accessibility API see notification banners, including mirrored iPhone ones, without opening Notification Center?** It runs alongside the database probe (`Prototype/probe/`, #4), whatever that one finds.

## Why it's safe

- **Metadata only.** It prints element roles and subroles, plus the **length** of identifiers and text, never the text itself. Words are read only to be counted, or checked against test words **you** chose, and are dropped immediately. The data type it builds from the screen has no field that could hold text.
- **Read-only.** It looks at Notification Center's on-screen elements; it never clicks, types or changes anything.
- **Stays on your Mac.** No network use.
- **You run it, not an AI.** The Accessibility permission goes to the Terminal app, never to Claude or another AI tool.

## Build (once)

In Terminal:

```
cd ~/Documents/Aegis/Prototype/accessibility && swift build -c release
```

The tool is then `.build/release/ax-probe` in that folder. Run the commands below from that folder.

## Run it (owner only)

1. **Accessibility for Terminal:** System Settings › Privacy & Security › Accessibility › turn on **Terminal** (add it with **+** if it isn't listed). Quit Terminal (⌘Q) and reopen it. This permission lets Terminal read and control other apps' windows, so turn it off again when Stage 0 is done.
2. **Check:** `.build/release/ax-probe check` should say Accessibility is allowed and Notification Center was found.
3. **Watch with your own test words.** The probe can tell you whether a banner's app, title and body are readable without ever showing them: you give it words you chose, and it answers yes or no for each.
   - **Mac test notification.** Start the watch:
     ```
     .build/release/ax-probe watch --expect-app "Script Editor" --expect-title "AEGIS TEST TITLE" --expect-body "AEGIS TEST BODY"
     ```
     Then, in a second Terminal window, send yourself a notification with those words:
     ```
     osascript -e 'display notification "AEGIS TEST BODY" with title "AEGIS TEST TITLE"'
     ```
     Each banner prints a line such as `app: yes  body: yes  title: yes`.
   - **iPhone-only apps.** Ask someone to message you in an app that's only on your iPhone, with a test word like `AEGIS TEST 7` as the message. Watch with `--expect-app "<the app's name as the banner shows it>" --expect-body "AEGIS TEST 7"`, under the same conditions as #4 (phone locked, unlocked, away).
   - Also try it with the **Mac locked** for a minute, then unlocked, and with **Do Not Disturb or a Focus** on if you use one.
   - Without `--expect-…` words, `watch` shows the number and length of each banner's text fields instead.
   - It stops by itself after 10 minutes; Ctrl-C stops it sooner.
4. **Notification Center open vs closed:** with nothing on screen, run `.build/release/ax-probe tree`. Then open Notification Center (click the clock in the menu bar) and run `tree` again. Older notifications that appear only in the second run mean history is readable only by opening Notification Center, which would break Aegis's silent rule.

## What to record in issue #10

- Banners shown vs banner lines printed, for each condition
- For each condition: whether your app, title and body test words were found (yes/no), for Mac and iPhone-only apps
- The "Accessibility events" lines: which subscriptions worked, and whether any events arrived
- `tree` with Notification Center closed vs open: number of windows and banners found
- The subroles printed (for example `AXNotificationCenterBanner`), so the real app can match them

Never paste notification text anywhere; the tool doesn't print any.

## Commands

| Command | Shows |
| --- | --- |
| `check` | Whether Terminal has the Accessibility permission (macOS may prompt) and whether Notification Center is running |
| `tree` | The element structure of Notification Center's windows right now: roles, subroles, identifier and text lengths |
| `watch [--seconds N] [--interval S] [--expect-app/--expect-title/--expect-body TEXT]` | One line per new banner (time, kind, and either yes/no for your test words or text lengths), then a summary |

## Tests

`cd Prototype/accessibility && swift test` (Mac only; the core logic is tested on invented accessibility trees).

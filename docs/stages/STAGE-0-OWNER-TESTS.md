# Stage 0: your Mac tests, in one afternoon

> **Done 2026-10-08.** The results are in `STAGE-0-RESULTS.md` and Checkpoint A has passed. At Checkpoint A the owner made version 1 Mac-only (ADR-0007), so the iPhone steps below (Test 1's conditions, Test 2's step 4) are no longer needed and stay only as a record. Still to do: turn off Accessibility for Terminal, remove "Aegis Agent FDA Test" from Full Disk Access, and keep Full Disk Access for Terminal on for the one-day trial (#19).

Four short tests that only you can run, because they need your Mac, your permissions and your real notifications. Together they decide Checkpoint A, the Stage 0 decision point: how Aegis captures notifications, and whether the background-agent design holds. About **1½ hours** in all.

- **Use the Terminal app** (Applications › Utilities), not Claude's terminal panel. Permissions go to Terminal, never to an AI tool.
- **Nothing here shows message text.** The tools print app IDs, counts, times and yes/no only. Never paste message text anywhere.
- When you're done, **paste the filled-in templates into the chat**. Claude puts them on the issues.
- Claude has already checked that every tool passes its tests on today's code, and has built the two tools that need building.

## Before you start (10 min)

1. **Plug in the Mac.**
2. **Full Disk Access for Terminal:** System Settings › Privacy & Security › Full Disk Access › turn on **Terminal** (add it with **+** if it isn't listed). Then quit Terminal (⌘Q) and reopen it.
3. **Accessibility for Terminal:** System Settings › Privacy & Security › Accessibility › turn on **Terminal**.
4. **iPhone notifications on the Mac:** open the **iPhone Mirroring** app once, then check that System Settings › Notifications allows notifications from your iPhone.
5. **Test notifications:** the key test needs about 20 notifications from at least 3 apps that are **only on your iPhone**.
   - Good sources: a friend messaging you in Instagram, Snapchat or WhatsApp (if WhatsApp isn't on the Mac), a delivery, ride-share or banking app, or an airline app.
   - Ask your helper to put the word `AEGIS TEST` and a number in each message.

## Test 1: can Aegis see your iPhone's notifications? (#4, 30–45 min, the key test)

1. Paste into Terminal:
   ```
   python3 ~/Documents/Aegis/Prototype/probe/notification_probe.py summary
   ```
   You should see a table of apps and counts. If it says access was denied, Terminal doesn't have Full Disk Access yet (step 2 above, including quitting and reopening).
2. Start watching:
   ```
   python3 ~/Documents/Aegis/Prototype/probe/notification_probe.py watch
   ```
   Leave it running. Each notification prints one line: time, delay, app ID, and whether that app is on this Mac.
3. Have your helper send notifications under each condition below. For each one, count how many your **Mac displayed** and how many lines the **probe printed**:
   - iPhone **locked**, near the Mac
   - iPhone **unlocked and in use**
   - **iPhone Mirroring window closed**, then **open**
   - iPhone **in another room** (still on and online)
   - **Mac asleep** for a few minutes, then wake it
4. Dismiss one notification, then use **Clear All**, and watch whether the probe says "removed".
5. Press **Ctrl-C**. Then run the same command with `schema` instead of `watch` and keep the output; it shows table and column names only.

```
#4 results
macOS version:            iOS version:
Database found (summary worked): yes/no
Condition                         | Mac displayed | Probe printed | Typical delay
iPhone locked, near the Mac       |               |               |
iPhone unlocked, in use           |               |               |
Mirroring window closed           |               |               |
Mirroring window open             |               |               |
iPhone in another room            |               |               |
Mac asleep, then woken            |               |               |
App IDs of 2–3 test apps (and "on this Mac?" = no?):
Dismiss / Clear All showed as removed: yes/no
schema output: (paste)
```

## Test 2: can Aegis read banners on screen instead? (#10, 15–20 min)

Aegis's backup route, in case Test 1 misses notifications. The tool is already built.

1. Paste into Terminal:
   ```
   cd ~/Documents/Aegis/Prototype/accessibility
   .build/release/ax-probe check
   ```
   It should say Accessibility is allowed and Notification Center was found. If it says `no such file`, run `swift build -c release` there first.
2. Start watching, using your own test words:
   ```
   .build/release/ax-probe watch --expect-app "Script Editor" --expect-title "AEGIS TEST TITLE" --expect-body "AEGIS TEST BODY"
   ```
3. In a **second Terminal window** (⌘N), send yourself a test notification:
   ```
   osascript -e 'display notification "AEGIS TEST BODY" with title "AEGIS TEST TITLE"'
   ```
   The watch prints a line like `app: yes  body: yes  title: yes`.
4. **iPhone-only app:** stop with Ctrl-C and watch again with `--expect-app "<the app's name as the banner shows it>" --expect-body "AEGIS TEST 7"`. Ask your helper to send a message containing `AEGIS TEST 7`. Try it with the iPhone locked and unlocked, and with the Mac locked for a minute.
5. **Notification Center closed vs open:** with nothing on screen, run `.build/release/ax-probe tree`. Then open Notification Center (click the clock in the menu bar) and run `tree` again.

```
#10 results
check: Accessibility allowed yes/no, Notification Center found yes/no
Mac test notification: app yes/no, title yes/no, body yes/no
iPhone-only app, iPhone locked: app yes/no, body yes/no
iPhone-only app, iPhone unlocked: app yes/no, body yes/no
Mac locked then unlocked: anything missed? yes/no
"Accessibility events" lines: (paste)
tree, Notification Center closed: windows __, banners __
tree, Notification Center open:   windows __, banners __
Subroles printed: (paste)
```

## Test 3: does the background agent get Full Disk Access? (#11, 10 min)

The test app is already built. It never reads your data: it only checks whether it may *open* one protected system folder.

1. Open it:
   ```
   open ~/Documents/Aegis/Prototype/output/agent-fda/Aegis\ Agent\ FDA\ Test.app
   ```
   If macOS refuses, find it in Finder, right-click it, and choose Open.
2. Click **Register agent**. If the window says it *needs approval*, click **Open Login Items settings** and allow "Aegis Agent FDA Test".
3. Within 15 seconds, "Agent's last result" should say **NOT allowed**. (If it says **TEST INVALID**, stop and tell Claude.)
4. System Settings › Privacy & Security › Full Disk Access › **+** › choose `Aegis Agent FDA Test.app` (in `Documents/Aegis/Prototype/output/agent-fda`). Add nothing else.
5. Wait 30 seconds and read the result again. If it hasn't changed, click **Unregister agent**, then **Register agent**.
6. **Clean up:** Unregister agent, remove the app from Full Disk Access (select it, then **−**), and delete the app.

```
#11 results
Before Full Disk Access: ALLOWED / NOT allowed
After Full Disk Access:  ALLOWED / NOT allowed
Had to approve in Login Items: yes/no
Re-register needed in step 5: yes/no
Anything macOS showed along the way:
```

## Test 4: how fast does the AI model load from cold? (#18, 3–5 min)

1. Paste into Terminal:
   ```
   cd ~/Documents/Aegis
   sudo purge
   ```
   It asks for your Mac password. Nothing appears while you type it; press Return.
2. Straight away:
   ```
   Prototype/.venv/bin/python Prototype/model/benchmark.py --runs 1 --models 4b
   ```
   This takes about 2 minutes. The Mac gets warm, which is normal. It uses invented test events only.

```
#18 results
First line printed (it starts "Qwen3.5-4B"): (paste)
```

## Afterwards

- Turn **Accessibility for Terminal** off again. Leave **Full Disk Access for Terminal** on until the one-day trial (#19), or turn it off now and back on then.
- Paste the four filled-in templates into the chat. Claude records them and prepares the Checkpoint A decisions with you.

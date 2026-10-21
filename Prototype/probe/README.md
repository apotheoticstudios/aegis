# Notification probe (Stage 0, issue #3)

Answers the Stage 0 key question on your own Mac: **are iPhone notifications shown through iPhone Mirroring recorded in the Mac's Notification Center database, and under which app ID?** The answer decides how Aegis covers the iPhone (issue #4).

## Why it's safe

- **Metadata only.** It shows app IDs, times and counts. It never reads the part of the database that holds titles and message text, and a test checks that.
- **Read-only.** It opens the database read-only and never changes it. If macOS won't allow a read-only open, it reads a private temporary copy and deletes it straight away.
- **Stays on your Mac.** Python standard library only, no network.
- **You run it, not an AI.** Only the owner runs it on the real database. Agents and tests use an invented database.

## Run it (owner only)

Use the **Terminal** app (Applications › Utilities), not Claude's terminal panel. Full Disk Access goes to whichever app runs the script; giving it to Terminal keeps Claude away from your data.

1. **Full Disk Access for Terminal:** System Settings › Privacy & Security › Full Disk Access › turn on **Terminal** (add it with **+** if it isn't listed). Quit Terminal (⌘Q) and reopen it.
2. **iPhone notifications on the Mac:** set up iPhone Mirroring if you haven't (open the iPhone Mirroring app once), and in System Settings › Notifications check that notifications from your iPhone are allowed.
3. **Check access:** paste this into Terminal:
   ```
   python3 ~/Documents/Aegis/Prototype/probe/notification_probe.py summary
   ```
   You should see a table of apps and counts. "on this Mac? = no" means no Mac app has that ID, so it probably came from your iPhone.
4. **Watch live:** run the same command with `watch` instead of `summary`, and leave it running. Each new notification prints one line: time, delay, whether the app is on this Mac, and the app ID.
5. **Run at least 20 test notifications from at least 3 apps that are only on your iPhone** (a bank, delivery or ride-share app, or ask someone to message you in one). For each condition below, count how many notifications **your Mac displayed** and how many lines **the probe printed**:
   - iPhone **locked**, near the Mac
   - iPhone **unlocked and in use**
   - the **iPhone Mirroring window closed**, then open
   - iPhone **away** (another room or out of Bluetooth range, still switched on and online). Apple says forwarding may still work; this checks it
   - **dismiss** one notification, then use **Clear All**, and see whether the probe says they were removed
   - put the **Mac to sleep** for a few minutes, trigger a notification, wake it
6. Press **Ctrl-C** to stop. Read the summary at the end.
7. Run it with `schema` instead of `watch` and copy the output (table and column names only).
8. Optional: turn Terminal's Full Disk Access back off.

## What to record in issue #4

- For each condition: notifications displayed on the Mac vs lines the probe printed
- The app ID shown for one or two of your test apps, and whether "on this Mac?" said `no`
- Typical delay, and how long records stayed before being removed (dismiss, Clear All)
- Your macOS and iOS versions, and the `schema` output
- If the probe can't find the database: run `sudo lsof -p $(pgrep -x usernoted) | grep db2` in Terminal and paste only the path it shows, with `/Users/<your name>` replaced by `~`

Never paste message text into the issue or any AI chat. The probe doesn't show any, and nothing else should.

## Commands

| Command | Shows |
| --- | --- |
| `schema` | Table and column names |
| `summary` | Notifications per app, newest time, whether the app is on this Mac |
| `recent --minutes 60` | Notifications delivered in the last N minutes |
| `watch [--interval 1]` | One line per new notification, live, plus removals; summary on Ctrl-C |

Every command takes `--db PATH` to point at a different database (tests use this with a synthetic one).

## Tests

`make test-prototype` (synthetic database only; runs on Linux in CI).


# WhatsApp store probe (Stage 2 step 0.2)

Answers: can Aegis read the WhatsApp Mac app's local store, and what shape is it? It prints **structure only**: whether the store exists and opens, table and column names, row counts, counts of chat ID kinds (`@s.whatsapp.net`, `@g.us`, `@lid`, …) and the first and last message day. It never prints message text, names, numbers or IDs (a test checks that), and it reads a private temporary copy, deleted straight away.

Run it in the **Terminal** app (it needs Full Disk Access, as above), with the WhatsApp Mac app installed and signed in:

```
python3 ~/Documents/Aegis/Prototype/probe/whatsapp_probe.py
```

Paste the output to Claude. If it says "not plain SQLite", the store is encrypted and WhatsApp stays on its Mac notifications.

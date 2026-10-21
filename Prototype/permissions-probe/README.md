# Signed launch and permissions probe (Stage 1, issue #66)

AegisCore will be a **background agent** that macOS starts, not the app you see. Stage 0 showed that one Full Disk Access grant to the app reaches the agent (#11, ADR-0010). This probe answers the rest, with a properly signed build:
- Does registering the agent need approval in Login Items?
- Do **Calendar, Reminders and Contacts** permissions given to the app reach the agent?
- Do grants survive a **rebuilt** app (same signing identity) and a **restart**?
- What happens when you **revoke** a permission while the agent is running?

The answer decides where Aegis's Calendar, Reminders and Contacts readers live (Checkpoint 1). If the agent doesn't get the app's permissions, the app reads them and hands snapshots to the agent over XPC.

The probe shows **only yes/no answers and counts**: how many calendars and reminder lists are visible, and whether one contact can be opened with no fields read. It never reads or saves an event, reminder, name or number. Results stay on this Mac in `~/Library/Application Support/AegisPermissionsProbe/`.

## Build (Claude does this)

```bash
Prototype/permissions-probe/build.sh
```

It needs the Apple Development certificate (Xcode › Settings › Accounts › Manage Certificates) and signs with the hardened runtime, like a real release.

## Run it (owner)

Open `Prototype/output/permissions-probe/Aegis Permissions Probe.app`. The window has an **App** column and an **Agent** column; the agent refreshes every 15 seconds.

1. Click **1. Register agent**. Note the agent status: *enabled*, or *needs approval* (then use **Open Login Items settings** and allow it).
2. Before granting anything, the Agent column should say *notDetermined* for Calendar, Reminders and Contacts and *denied* for Full Disk Access.
3. Click **2. Ask for Calendar, Reminders, Contacts** and allow all three prompts (Allow Full Access). Wait 30 seconds. **Does the Agent column change to fullAccess / authorized, with counts?**
4. Give the app Full Disk Access: System Settings › Privacy & Security › Full Disk Access › **+** › the probe app. Wait 30 seconds. **Does the agent show allowed?**
5. **Revoke while running:** System Settings › Privacy & Security › Calendars › turn the probe app off. Wait 30 seconds. **What does the agent show?** Turn it back on.
6. **Rebuilt app:** quit the probe, tell Claude to rebuild it, open it again. **Do both columns keep their grants?**
7. **Restart** the Mac, open the probe. **Does the agent still have every grant?**
8. Click **Copy results** and paste them to Claude (statuses and counts only).

## Stage 2 probe 0.1: notification banners (owner)

Answers: can Aegis's background agent watch notification banners through the Accessibility API, or only the app? Which events fire when a banner appears? It counts events and records element **types** only (for example `AXWindow/AXNotificationCenterBanner`), never titles or text.

1. Open the probe app. If the agent isn't registered, click **1. Register agent**.
2. Give the probe app Accessibility: System Settings › Privacy & Security › Accessibility › **+** › the probe app. Wait 30 seconds. **Does the Agent column's Accessibility row say trusted?**
3. Click **Reset banner counts**, then **3. Watch banners for 60 s (app)**, and straight away paste this into Terminal (it shows 5 test banners, one every 5 seconds):
   ```
   for i in 1 2 3 4 5; do osascript -e "display notification \"Probe test $i\" with title \"Aegis probe\""; sleep 5; done
   ```
4. When the app says *Watched 60 s*, look at **Banner events** in both columns: 5 banners should give events in each column that can see them.
5. Click **Copy results** and paste them to Claude (counts and element types only).
6. Clean up as below, and also remove the probe from Accessibility.

## Clean up

Click **Unregister agent**, remove the probe from Full Disk Access, Calendars, Reminders and Contacts in System Settings › Privacy & Security, then delete the app.

## Files

| File | What it is |
| --- | --- |
| `Sources/ProbeShared/Probe.swift` | The checks, shared by the app and the agent: statuses and counts only |
| `Sources/probe-app/` | The window: register, ask for access, show both columns, copy results |
| `Sources/probe-agent/main.swift` | The agent: runs the checks and writes `agent-result.json` |
| `Resources/` | The app's `Info.plist` with the permission texts, the agent's launchd plist (`AssociatedBundleIdentifiers`), and the hardened-runtime entitlements |
| `build.sh` | Builds, assembles and signs with the Apple Development identity |

# Background agent + Full Disk Access check (Stage 0, issue #11)

Aegis's always-on part (AegisCore) will be a **background agent** that macOS starts, not the app you see. This test answers: **if you give Full Disk Access to the Aegis app, does its background agent get it too, or would users need a second, confusing permission step?**

The test app registers a tiny agent with macOS (`SMAppService`, the standard way since macOS 13). Every 15 seconds the agent tries to **open** a folder macOS protects with Full Disk Access (`/Library/Application Support/com.apple.TCC`, the system's privacy-permissions folder) and closes it straight away. It reads nothing inside it and never touches messages, mail or notifications; it reports only whether opening was allowed.

## Build (once)

In Terminal:

```
~/Documents/Aegis/Prototype/agent-fda/build.sh
```

It prints where the app is: `Prototype/output/agent-fda/Aegis Agent FDA Test.app`.

## Run it (owner only)

1. **Open the app** (double-click it in Finder). It's signed only for this Mac, so if macOS refuses, right-click it › Open.
2. Click **Register agent**. macOS may show a "Background Items Added" notice; if the window says the agent *needs approval*, click **Open Login Items settings** and allow "Aegis Agent FDA Test".
3. **Without Full Disk Access:** within 15 seconds, "Agent's last result" should say **NOT allowed** (an "Operation not permitted" error). This shows the test works. If it says **TEST INVALID**, stop and tell Claude.
4. **Give Full Disk Access to the app only:** System Settings › Privacy & Security › Full Disk Access › **+** › choose `Aegis Agent FDA Test.app`. Don't add anything else.
5. Wait about 30 seconds and read the result again. If it doesn't change, click **Unregister agent**, then **Register agent** (some macOS versions only apply new permissions to freshly started processes).
6. **Clean up:** click **Unregister agent**, remove the app from Full Disk Access (select it, **−**), and delete the app.

## What to record in issue #11

- The result before and after step 4: **ALLOWED** or **NOT allowed**, and the error shown
- Whether you had to approve it in Login Items, and what macOS showed you along the way
- Whether step 5's re-register was needed
- Your macOS version

**What the answers mean:** *ALLOWED after step 4* means one Full Disk Access grant to the Aegis app is enough. *NOT allowed* means the agent needs its own grant (or a different design), which changes Stage 1.

## Files

| File | What it is |
| --- | --- |
| `Sources/fda-test-app/` | The test app: register/unregister buttons and the agent's last result |
| `Sources/fda-agent/main.swift` | The agent: opens and closes the protected folder (no entry read), writes yes / no / invalid and any error to `~/Library/Application Support/AegisAgentFDATest/agent-result.json` |
| `Resources/` | The app's `Info.plist` and the agent's launchd plist (runs at load and every 15 s) |
| `build.sh` | Builds both, assembles the app bundle, signs it ad hoc for local testing |

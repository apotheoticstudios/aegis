# ADR-0013: Background processes, permissions and signing

- **Status:** accepted (Stage 1 Checkpoint 1 input; revocation, rebuild and restart checks pending on #66)
- **Date:** 2026-10-09
- **Proposed by:** Claude, from spikes 1.4 (#66) and 1.5 (#67), with ChatGPT's research on #67 · **Approved by:** human (Stage 1 plan)

## Context
Stage 1 needs AegisCore (always on, a launch agent) to ask ModelService (loads the model on demand, then exits) for briefs while the app is closed. AegisCore must also read Calendar, Reminders and Contacts. Both depend on how macOS starts, trusts and grants permissions to background processes. Results: `docs/stages/STAGE-1-SPIKES.md` sections 1.5 and 1.5b, and #66.

## Options considered
**How AegisCore reaches ModelService**
1. **ModelService as its own on-demand `SMAppService` launch agent with a `MachServices` entry.**
2. An XPC service embedded in the app: only the app can reach it, and the app is usually closed.
3. The app as a broker: needs the app running.

**Where Calendar, Reminders and Contacts are read**
1. **In AegisCore,** if the app's grants reach the agent.
2. In the app, passing snapshots to AegisCore over XPC (the fallback).

## Decision
- **ModelService is an on-demand MachService launch agent** (option 1). launchd starts it in about 0.2–0.4 s when AegisCore connects, with the app closed. It exits by itself after its job and a short idle grace; launchd never stops it. No `RunAtLoad`, no `KeepAlive`. **`ThrottleInterval` is 1 s**: launchd's default 10 s delayed a relaunch by up to 9.4 s after a crash. AegisCore retries an interrupted job with backoff, so a crashing ModelService can't cause a restart storm.
- **Both ends check code signatures,** with requirements pinned to Apple's anchor, Aegis's own team and the expected identifier. An ad hoc impostor that copies AegisCore's identifier is refused.
- **AegisCore reads Calendar, Reminders and Contacts itself.** With `AssociatedBundleIdentifiers` in the agent's plist, the grants the user gives the app reached the agent: Full Disk Access, Calendar, Reminders and Contacts (probe on the owner's Mac, macOS 26.6.2).
- **Sign with the team from the very first registration.** macOS remembers an agent's first signature: the spike's labels, first registered ad hoc, were killed at launch once team-signed ("Launch Constraint Violation"). AegisCore and ModelService are never registered ad hoc, not even in tests.

## Consequences
- The setup wizard asks once for Full Disk Access, Calendar, Reminders and Contacts, all for Aegis; registration needed no Login Items approval on this Mac.
- **Certificate renewal would reset permissions.** An Apple Development signature's designated requirement pins the certificate itself, which renews yearly. Mitigation to test (#66): sign with an explicit designated requirement on the team and identifier (`codesign -r=`), so grants survive a renewed certificate of the same team.
- **Changing team breaks registrations.** The owner's free Personal Team has its own team ID; joining the paid Developer Program later gives a different one. That move needs new agent labels (or a Background Items reset) and new permission grants: plan it as a one-time migration.
- Still to confirm on #66: the agent's behaviour when a permission is revoked while it runs, after a rebuild with the same identity, and after a restart. If any fails, the fallback (the app reads and passes snapshots) remains available.

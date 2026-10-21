# ADR-0010: AegisCore is an SMAppService launch agent covered by the app's Full Disk Access

- **Status:** accepted (Checkpoint A)
- **Date:** 2026-10-08
- **Proposed by:** Claude, from #11 · **Approved by:** human

## Context
AegisCore must read protected stores (the notification database, Messages, Mail) while the panel is closed, as a background agent. Each store needs Full Disk Access. Stage 0 asked whether granting it to the app covers an agent the app registers with `SMAppService`.

## Options considered
1. **Grant Full Disk Access to the app, and let its agent inherit it.**
2. **A separate grant for the agent:** a second, confusing step for the user.
3. **Run the collectors inside the app:** no agent, but no capture while the app is closed, which breaks "thoughtless".

## Decision
Option 1. The owner's test (#11, macOS 26.6.2) behaved like this:
- the agent was refused before the grant;
- it was allowed within about 30 s of granting Full Disk Access to the app only;
- it was started by launchd and needed no re-registration.

## Consequences
- The setup wizard asks for Full Disk Access once, for Aegis.
- The test app was ad hoc signed, so these need a Developer ID-signed build in Stage 1:
  - whether macOS asks for Login Items approval when the agent is first registered;
  - whether the grant survives moving or re-signing the app.
- If the grant is lost, readers report `permission_denied`, and the panel shows a one-line fix (self-healing).

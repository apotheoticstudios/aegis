# ADR-0007: Mac-first capture; no iPhone component or hardware in version 1

- **Status:** accepted (owner's decision at Checkpoint A)
- **Date:** 2026-10-08
- **Proposed by:** Claude, from the Stage 0 evidence · **Approved by:** human

## Context
Stage 0 had to decide how Aegis captures notifications, especially from apps that exist only on the iPhone (`docs/stages/STAGE-0.md`, Done when 1). The owner's Mac tests (#4, #10) on 2026-10-08 showed:
- The Notification Center database captures every Mac notification (median delay about 5.75 s). A record disappears when its notification is dismissed.
- The Accessibility API reads the app, title and body of live banners within about 1 s, silently. Earlier notifications are only visible with Notification Center open, which breaks the silent rule.
- Messages from an iPhone-only app, with the phone locked, reached neither recorder. A paired Apple Watch showed them instead.
- iPhone-to-Mac forwarding depends on iPhone Mirroring and on the phone being near the Mac. The phone is often away from the Mac, so it was judged not viable.

## Options considered
1. **iPhone Mirroring forwarding:** Apple's only bridge, software-only. It failed as tested, needs the phone nearby, and its routing alongside an Apple Watch isn't documented.
2. **An iPhone companion app:** iOS lets no app read other apps' notifications, so it can't capture them. It could still send context (location, Focus, battery) later.
3. **A Bluetooth notification accessory (ANCS):** a small board plugged into the Mac, which the iPhone treats like a smartwatch. It is reliable while the phone is in range, but it is extra hardware. Reports also say a Mac can't take that role itself.
4. **iOS 27's Shortcuts trigger, "When a notification is received":** unverified whether it passes the notification text; not tested because the iPhone route was dropped first.
5. **Mac-first:** read accounts at their source (Mail, iCloud Messages, SMS forwarded to the Mac, Calendar), prefer Mac or web versions of apps, and record every Mac notification.

## Decision
Option 5. Version 1 is Mac-only:
- The notification database recorder is the main route, watching for changes and copying records as they arrive.
- The Accessibility recorder is a backup for live banners only.
- Direct sources (Messages, Mail, Calendar; WhatsApp and Telegram later) give full content, with duplicates merged.

Version 1 has no iPhone component and no hardware. Alerts from apps that push only to the iPhone aren't captured, unless the service also sends an email, an SMS or a web alert. iPhone Mirroring and a context-only companion app stay possible later additions (DESIGN.md, "Optional later: iPhone").

## Consequences
- **Easier:** nothing depends on where the phone is, there is nothing to pair or charge, and Stage 2's recorders are the ones Stage 0 measured.
- **Harder:** banking, delivery and ride-share alerts that only reach the iPhone are a known gap; the setup wizard should suggest each service's email, SMS or web alerts instead.
- **Watch:**
  - Notifications that reach only the Mac are missed while it is asleep or off; cloud sources catch up on wake.
  - Apple may change the database format; two recorders reduce that risk.
  - The database delay (about 6 s) is fine for batches every few minutes but misses Stage 0's 5 s bar.

# ADR-0008: Email through Apple Mail; work Microsoft 365 accounts through Outlook's notifications for now

- **Status:** accepted (owner's decision, 2026-10-08)
- **Date:** 2026-10-08
- **Proposed by:** Claude, from the #19 trial · **Approved by:** human

## Context
The one-day trial (#19) read no email. Apple Mail's store was readable but had nothing in 24 hours: on the test Mac, email was read in other apps (Outlook, webmail), not Apple Mail. Aegis's Mail reader (#16) reads Apple Mail's local store. Two facts constrain the alternatives:
- Since September 2024, Microsoft requires its modern sign-in for Outlook.com in other apps; a plain or app password no longer works (Microsoft support, "Modern Authentication Methods now needed…").
- On 1 October 2026 Microsoft began switching off Exchange Web Services (EWS) for Microsoft 365, with full removal on 1 April 2027. Apple Mail on the Mac uses EWS for Exchange accounts, so work accounts in Mail may stop syncing. Apple has promised Microsoft Graph support in a macOS 27 update, without a date (MacRumors, 1 October 2026; Michael Tsai, 20 August 2026).

## Options considered
1. **Apple Mail fetches; Aegis reads Mail's local copy.** Apple's own sign-in handles Google and Microsoft accounts. The reader is already built, and Aegis adds no internet code. Mail must be running to fetch.
2. **Notifications only:** Outlook's Mac notifications and Gmail's website notifications, caught by the notification recorder. No setup, but only the sender, subject and a preview.
3. **Aegis connects itself** (IMAP with OAuth, Microsoft Graph, the Gmail API): full control, but Aegis must be registered with Microsoft and Google, and it adds network code and credentials.
4. **Read the Outlook app's own files:** undocumented and fragile.

## Decision
- **Personal accounts (Gmail, Outlook.com):** option 1. The owner adds them to Apple Mail once (System Settings › Internet Accounts). Mail runs hidden in the background, and Aegis checks that it is running.
- **Work or school Microsoft 365:** option 2 for now. Revisit when Apple Mail supports Microsoft Graph, and only if the organisation allows it.
- No IMAP or other mail network code in Aegis for version 1.

## Consequences
- Full emails and threads for personal accounts; the sender, subject and preview for the work account.
- Mail has to keep running, which uses its own memory, and it keeps a local copy of the mail, which uses disk. Setting attachment downloads to "Recent" or "None" limits that.
- Mail's own notifications can be turned off so alerts aren't doubled.
- The Mail reader has only read fixtures so far. Its first real-data check is a Stage 1 task, once the accounts have synced.
- The setup wizard helps add accounts to Apple Mail and explains the work-account limit.

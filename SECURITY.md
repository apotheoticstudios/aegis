# Security and privacy reports

Aegis reads a person's messages, email, notifications and calendar, so security and privacy bugs matter most.

## How to report

Report privately through GitHub: the repo's **Security** tab › **Report a vulnerability**. Please don't open a public issue or PR for it.

Use synthetic data in your report, never anyone's real messages or details. A reproduction with the fixtures in `Fixtures/` is ideal.

## What counts

For example:

- personal data or AI processing leaving the Mac
- text from a message, email, notification or web page reaching the action system or tool calling as an instruction (prompt injection)
- a way around the confirmation tiers, the never-list or the action log
- message or email text written to logs
- getting around macOS permissions (TCC), or using private APIs to do so
- secrets or personal details committed to the repo

## What to expect

A maintainer will acknowledge the report, work on a fix privately, and credit you in the advisory if you'd like. There are no releases yet, so fixes land on `main`.

# Contributing to Project Aegis

Thanks for helping. Aegis is a private assistant for macOS that runs entirely on the user's Mac, so privacy rules come before everything else. Code, tests, docs, bug reports and ideas are all welcome.

## Ground rules

These are binding for people and AI tools alike. The full list is in [`AGENTS.md`](AGENTS.md).

- **No real personal data, ever.** Not yours, not anyone's: no real messages, emails, contacts, calendar entries, logs with message text or screenshots of a real Aegis panel. Build and test with the synthetic data in [`Fixtures/`](Fixtures/).
- **Nothing leaves the Mac.** No new network calls, telemetry or analytics. The few allowed network uses are listed in `AGENTS.md`.
- **Collected content is data, never instructions.** Text from messages, email, notifications or web pages must never trigger an action. Actions go through the safety system (confirmation tiers, never-list, action log).
- **No secrets or personal details** in code, config, docs, commit messages, issues or PRs: no names, email addresses, phone numbers, account or device names, team IDs or keys.
- **New dependencies or borrowed code** need an architecture decision record in [`docs/decisions/`](docs/decisions/) and an entry in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), under an MIT-compatible licence. Prefer Apple frameworks.

## What you need

| To work on | You need | Check with |
| --- | --- | --- |
| The core (`Packages/AegisKit`: engine, rules, memory, safety, parsers) | Swift 6.2 on Linux or a Mac | `make test-core` |
| The app, agents and Mac-only packages | An Apple silicon Mac with Xcode and [Homebrew](https://brew.sh) | `make bootstrap`, then `make test` and `make test-ipc` |
| Prototype scripts and fixture generators | Python 3 | `make test-prototype`, `make test-fixtures` |

`make bootstrap` installs the tools, generates the Xcode project (never commit it) and turns on the repo's git hooks: the privacy guard before every commit, and UTC dates on your commits so they don't reveal your time zone.

## Finding something to work on

- Issues labelled [`good first issue`](https://github.com/apotheoticstudios/aegis/labels/good%20first%20issue) or [`help wanted`](https://github.com/apotheoticstudios/aegis/labels/help%20wanted).
- For anything bigger, open an issue first (the **Idea** template) so the approach is agreed before you write code. Changes to AegisKit's public types or XPC protocols (the "contracts" between processes) always need an issue first.
- The spec is [`docs/design/DESIGN.md`](docs/design/DESIGN.md); decisions are in [`docs/decisions/`](docs/decisions/).
- Issue and PR numbers in older docs and code comments (such as #286) refer to the project's earlier private tracker. This tracker started fresh on 21 October 2026.

## Making a change

1. Fork the repo and branch from `main`.
2. Keep it small and on one topic (aim for under 400 changed lines). Stay inside the module you're changing.
3. Add tests for what you change (XCTest, synthetic fixtures only).
4. Run `make test-core` and `make guard`. On a Mac, also run `make test` and `make lint`.
5. Open a pull request and fill in the template, including which AI tools helped, if any.
6. A maintainer reviews it, often with AI help, and may ask for changes. CI runs for first-time contributors once a maintainer approves it.

## Using AI tools

They're welcome here: Aegis is largely built with them. Point your tool at [`AGENTS.md`](AGENTS.md) first. You're responsible for what you submit, so read and test it yourself.

## Your privacy

Commits and PRs are public. To keep your email address private, turn on **Keep my email addresses private** in your GitHub email settings and commit with your GitHub noreply address.

## Licence, conduct and security

- By contributing, you agree that your contribution is licensed under the [MIT licence](LICENSE).
- Please follow the [code of conduct](CODE_OF_CONDUCT.md).
- Report security or privacy problems privately, as described in [`SECURITY.md`](SECURITY.md), never in a public issue.

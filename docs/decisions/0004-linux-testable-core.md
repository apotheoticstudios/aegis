# ADR-0004: A Linux-testable core package (AegisKit)

- **Status:** accepted
- **Date:** 2026-10-07
- **Proposed by:** Claude · **Approved by:** human

## Context
Codex's cloud environments cannot build macOS apps. To use Codex as a real builder (not only a reviewer), a meaningful part of the code must build and test on Linux.

## Decision
`Packages/AegisKit` is a plain Swift package with no Apple-only frameworks: event model, rules engine, triage pipeline logic, parsers over bytes/rows, prompt builders, XPC message types. macOS-specific code lives in app targets behind protocols defined in AegisKit. CI runs `swift test` for AegisKit on Linux for every PR.

## Consequences
Codex (and any cloud agent) can build and test core logic; the core is well-tested and decoupled from UI. Requires discipline: no AppKit/SwiftUI/EventKit/etc. imports in AegisKit (enforced by `make guard` and review rules).

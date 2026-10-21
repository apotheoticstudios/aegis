# ADR-0003: Generate the Xcode project with XcodeGen

- **Status:** accepted
- **Date:** 2026-10-07
- **Proposed by:** Claude · **Approved by:** human

## Context
Several AI agents will add files and targets in parallel. Xcode's `.pbxproj` files are hard to merge and easy for agents to corrupt.

## Decision
The project is described in `project.yml` and generated with XcodeGen (`make generate`). `Aegis.xcodeproj` is gitignored. Agents edit `project.yml`, never the generated project.

## Consequences
No project-file merge conflicts; the project is reviewable as text. Everyone must run `make generate` after pulling changes to `project.yml` (the bootstrap and Makefile handle this).

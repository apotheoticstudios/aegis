# ADR-0001: Native Swift app, app-first, with AegisShell as an optional layer

- **Status:** accepted
- **Date:** 2026-10-07
- **Proposed by:** Claude · **Approved by:** human

## Context
Aegis must read macOS data stores, control apps and HomeKit, render a GPU HUD, run local models, and stay silent and light in the background.

## Options considered
1. Native Swift (SwiftUI/AppKit, Metal, MLX Swift).
2. Electron or a web app.
3. Python as the product.
4. A "real OS" replacing macOS components.

## Decision
Native Swift, split into small processes (app, Core launch agent, on-demand model XPC service, Catalyst HomeKit helper, WidgetKit extension, World sidecar). Build the app first; AegisShell is an activatable shell layer on top, never a replacement for macOS components. Direct distribution (Developer ID + notarization), not the Mac App Store.

## Consequences
Best performance, lowest idle RAM and full API access. Requires a Mac with Xcode for app work, which shapes how AI agents split work (ADR-0002, ADR-0004).

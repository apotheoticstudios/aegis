# Design

| Item | Where |
| --- | --- |
| **Spec (canonical for all agents)** | [`DESIGN.md`](DESIGN.md) |
| Spec, editable mirror (Claude Doc) | https://claude.ai/code/artifact/236e0ea6-05c9-4ccb-a5a5-98f47984d52f (private to the owner) |
| UI concepts canvas (17 screens: HUD, panel views, World view, menu bar, settings, wizard) | https://claude.ai/artifact/JCCJW4Xp2qqP6BWaqS4DCA (private to the owner) |
| Aegis Mode visual design brief (hand to the design system) | [`aegis-mode-brief.md`](aegis-mode-brief.md); build plan in [`../stages/AEGIS-MODE.md`](../stages/AEGIS-MODE.md) |
| Open-source reference projects (what other readers and assistants do, with licences) | [`open-source-references.md`](open-source-references.md) |
| **Design system** (tokens for five themes, type, components, motion, character art and the five worked screens; ADR-0029) | https://claude.ai/artifact/WDtq5FE2vqSP9gqvpQcXjt (the owner's) |
| Reactor core animation (WebGL prototype) | [`prototypes/reactor.html`](prototypes/reactor.html) — open in a browser; live version: https://claude.ai/artifact/Db1bzS4tYfJVYsi8a1WLhm |

The claude.ai links are private to the owner. Other AIs work from `DESIGN.md` and the prototype in this folder; ask the owner for screenshots of the canvas when a task needs the UI concepts.

## Keeping the spec in sync
- Design decisions are made in a PR that edits `DESIGN.md` (plus an ADR when significant).
- After merging, Claude updates the Claude Doc mirror, and the owner re-uploads `DESIGN.md` to the ChatGPT "Aegis" project.

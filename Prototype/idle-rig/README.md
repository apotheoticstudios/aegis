# Empty-shell memory rig (Stage 0, issue #12)

How much of Aegis's 300 MB idle budget is used before writing any feature? This rig runs the smallest possible versions of Aegis's two always-on parts and measures them:

| Process | Stands in for | What it does |
| --- | --- | --- |
| `idle-menubar` | AegisApp with the panel closed | An empty SwiftUI app with a menu-bar icon (a hexagon) and no Dock icon |
| `idle-agent` | AegisCore before any collector runs | An empty background process that wakes once a minute |

`measure.py` builds both, runs them, and samples each one's **memory footprint** with macOS's `footprint` tool: dirty memory, what Activity Monitor's "Memory" column shows, not RSS, which double-counts shared pages. It prints a median, minimum and maximum, and flags a combined median above 100 MB (the threshold in `docs/stages/STAGE-0.md`).

```
python3 Prototype/idle-rig/measure.py --minutes 30 --interval 60
```

Samples go to `Prototype/output/idle-rig/samples.csv` (gitignored). Synthetic: it touches no personal data. The result is a **lower bound**; Stage 1 measures the real processes.

Result on the target Mac: see `docs/stages/STAGE-0-RESULTS.md` › Empty-shell memory footprint.

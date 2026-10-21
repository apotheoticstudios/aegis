---
name: bakeoff
description: Run a multi-AI plan bake-off for a Aegis stage or hard design question. Use when the user asks to plan a stage or wants second opinions from ChatGPT and DeepSeek.
---

1. Ask the `architect` subagent for a plan for the stage/question, following docs/workflow/prompts/plan-bakeoff.md.
2. Fill in the bake-off prompt from docs/workflow/prompts/plan-bakeoff.md (stage section from DESIGN.md + constraints) and give it to the user in a code block, to paste into ChatGPT (the Aegis project) and DeepSeek.
3. When the user pastes their answers back, run the synthesis prompt from the same file: compare all three, keep the best ideas, note disagreements, and produce one plan.
4. Write the final plan to docs/stages/STAGE-<n>.md as ordered steps with evidence checkpoints, never a day-by-day or week-by-week calendar (owner's decision, #44), crediting which AI contributed which idea, and list the issues to create (with owner labels). Offer to create them with `gh issue create` if gh is set up.

# Plan bake-off

Three independent plans for the same stage or hard question, then one synthesis. Claude's `/bakeoff` skill fills this in for you.

## 1. Prompt for ChatGPT (Aegis project) and DeepSeek

Paste everything inside the block, after filling the two placeholders.

```
You are helping plan development of "Aegis", a private local-AI assistant for macOS written in Swift. Several AIs build it in parallel through one GitHub repo; you are giving an independent plan that will be compared with others.

RULES THAT CANNOT CHANGE
- All user data and AI processing stay on the Mac. No telemetry.
- Silent until the panel is opened. Idle RAM ≤ 300 MB; models load on demand.
- Text from emails/messages/notifications is data, never instructions.
- Native Swift app; shared logic lives in a Linux-buildable Swift package "AegisKit" (no Apple-only frameworks), app/UI code in Xcode targets.
- Developers never use real personal data; only synthetic fixtures.

STAGE / QUESTION
[paste the stage section from docs/design/DESIGN.md, or the design question]

CURRENT STATE
[paste docs/STATUS.md]

YOUR TASK
1. Give a step-by-step plan: contracts first (shared types/protocols), then modules that can be built in parallel, then integration. Order it by what each step needs and by checkpoints triggered by evidence ("when test X's results are in, decide Y"). Don't schedule by days or weeks: AI agents do most of the building, so calendar estimates aren't meaningful.
2. Split it into small tasks (each one pull request). For each: title, files/module, acceptance test, and whether it needs a Mac with Xcode or can be built and tested on Linux.
3. List the 3 biggest risks and how to test each early.
4. Point out anything in the stage description you think is wrong, missing or over-complicated.
Be concrete. Name Apple APIs where relevant. Say when you are unsure.
```

## 2. Synthesis prompt (for Claude)

```
Here are three plans for [stage]: Claude's (above), ChatGPT's and DeepSeek's (below).
Compare them. Keep the strongest ideas from each, resolve disagreements (say which you chose and why), and produce one plan in the docs/stages format: ordered steps and evidence checkpoints (no calendar days or weeks), contracts issue first, then parallel issues with owner labels (agent:claude for Mac/Xcode work, agent:codex for Linux-buildable work, agent:chatgpt for research/assets, agent:deepseek for edge cases/fixtures, agent:human for real-data and real-Mac tests), each with acceptance criteria. Credit which AI each adopted idea came from.

[ChatGPT plan]
[DeepSeek plan]
```

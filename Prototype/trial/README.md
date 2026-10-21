# Trial runner: one real day, one command (issue #42, for the trial in #19)

Runs a day through everything Stage 0 built:
1. The readers (notifications, Messages, Mail) read the stores, read-only.
2. The pipeline merges duplicates and fits the day into the model's input.
3. The primary model (Qwen3.5-4B) writes the brief once, offline, in its own process.
4. The brief is checked against the contract.

You then score the brief yourself.

## Run it on your real day (owner only, Terminal with Full Disk Access)

```
cd ~/Documents/Aegis
Prototype/.venv/bin/python Prototype/trial/run_day.py
```

It takes about a minute, and the Mac gets warm.

**The terminal shows numbers only:**
- each source's status, events and problems;
- duplicates merged, and how many events didn't fit the input;
- the model's load time, time to first words and whole-brief time;
- peak memory, swap growth, and free memory before and after.

**The brief goes to a private file** that only you can read. Open it with the command the runner prints, e.g.:
```
open -e ~/Documents/Aegis/Prototype/output/trial/<date-time>/brief.md
```
Each item shows the message it cites, so you can check its facts. Fill in the score at the bottom and put only the numbers on issue #19, never message text.

The same folder also has `brief.json`, `input.txt` (exactly what the model saw) and `run.json` (numbers only). Git ignores `Prototype/output`. Delete the folder when you're done.

**Options:**
- `--hours N` sets the window (default 24).
- `--model 9b` uses the larger model (slower; swaps on 16 GB).

## Try it on fake data first (anyone)

```
python3 Fixtures/generate/generate.py /tmp/aegis-fixtures
Prototype/.venv/bin/python Prototype/trial/run_day.py --fixtures /tmp/aegis-fixtures
```

## For developers

`run_day.py` reuses:
- `Prototype/readers` (`read.py`'s `READERS` and `REAL_STORES`);
- `Prototype/pipeline` (`merge_events`, `build_input`);
- `Prototype/model` (`benchmark.run_once` for the model process and memory sampling; `briefing` for the prompt and the answer).

`test_trial.py` stubs the model, so CI needs no MLX. It checks four things:
- the whole chain runs on fixtures;
- no message text reaches the terminal or `run.json`;
- the files are private (0600, folder 0700);
- an unusable answer or a citation outside the input fails cleanly.

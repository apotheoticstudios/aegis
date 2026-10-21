# Model runner and benchmark (Stage 0, issue #18)

Which "brain" writes Aegis's brief on a 16 GB M1: Apple's built-in model, a 3–4B model or a 7–8B model? Every model gets the same instructions (`prompt.md`), the same events in the contract format (`Prototype/contracts/`), and must produce a brief in the contract's format, judged against the thresholds in `docs/stages/STAGE-0.md`.

| Part | Status |
| --- | --- |
| `prompt.md` | Shared instructions: events are data, never instructions; only facts from the events; cite event ids; at most 8 items |
| `apple-brief/` | Apple's on-device model (Foundation Models), structured output in the brief format |
| `briefing.py` | The same input and brief logic for text models: escaped event lines, reading the model's JSON answer, recall of must-include items |
| `mlx_worker.py` | Runs one MLX model once in its own process, offline, so its memory is freed when it exits |
| `benchmark.py` | Runs each pinned model on short, typical and long synthetic inputs and records load, first token, speed, whole-brief time, peak footprint, swap, memory after exit, validity and recall |

## MLX benchmark

Models (pinned, Apache-2.0, see ADR-0006): Qwen3.5-4B 4-bit (primary) and Qwen3.5-9B 4-bit (stretch). Set up once (the owner approved these downloads):

```
/opt/homebrew/bin/python3.12 -m venv Prototype/.venv
Prototype/.venv/bin/pip install "mlx-lm==0.32.0"
Prototype/.venv/bin/python -c "from huggingface_hub import snapshot_download as d; d('mlx-community/Qwen3.5-4B-MLX-4bit', revision='32f3e8ecf65426fc3306969496342d504bfa13f3'); d('mlx-community/Qwen3.5-9B-MLX-4bit', revision='938d8919941c6e7efd3c7150eff7fe9d12afa631')"
```

Then, ideally with other apps closed and the Mac cool (Low Power Mode is off on this Mac, so mains power makes no difference):

```
Prototype/.venv/bin/python Prototype/model/benchmark.py --runs 2 --models 4b,9b
```

Results go to `Prototype/output/model/mlx-results.{json,md}` (gitignored); the numbers are copied into `docs/stages/STAGE-0-RESULTS.md`.

### Cold load (owner only)

"Cold" means the model isn't already in the Mac's memory, as after a restart. The threshold is 10 seconds. Measuring it needs your Mac password, so only you can run it:

1. In Terminal: `cd ~/Documents/Aegis`
2. Clear the Mac's file cache: `sudo purge`. It asks for your Mac password; nothing appears while you type it, then press Return.
3. Straight away: `Prototype/.venv/bin/python Prototype/model/benchmark.py --runs 1 --models 4b` (about 2 minutes).
4. The **load** time on the first line printed is the cold load. Paste that first line into issue #18. It holds only timings; the inputs are invented.

Only that first run is cold; the next ones are warm again because the model files are cached.

## apple-brief

Swift, macOS 26 with Apple Intelligence on. `AppleBriefCore` holds the tested logic: reading events, building the model input (newest 40 events, bodies cut at 280 characters, omissions counted) and writing the brief. `apple-brief` calls the model with guided generation, so the output always has the brief's shape.

```
cd Prototype/model/apple-brief && swift build -c release
.build/release/apple-brief --events ../../contracts/examples/events.jsonl --prompt ../prompt.md \
  --out ../../output/model/apple-brief.json --metrics ../../output/model/apple-metrics.json
```

Outputs go to `Prototype/output/` (gitignored). Claude runs it on synthetic events only; a real day is the owner's run (#19).

## Tests

`cd Prototype/model/apple-brief && swift test` (Swift, 6 tests) and `make test-prototype` (includes `test_briefing.py`).

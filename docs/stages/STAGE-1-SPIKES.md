# Stage 1 spikes

Early checks that Stage 1's plan depends on (bake-off: #53). Numbers only, measured on the target Mac (MacBook Air M1, 16 GB, fanless, macOS 26.6.2, Xcode 27.0), synthetic data only.

## 1b: MLX Swift runs Qwen3.5-4B (#54), 2026-10-08

`Prototype/model-swift/` (ADR-0011) loads the pinned Qwen3.5-4B 4-bit files from disk with `mlx-swift-lm` 3.32.3 and writes the Stage 0 briefs with greedy decoding and thinking off, exactly as `Prototype/model/mlx_worker.py` does.
- **Inputs:** the same three spec files for both runtimes (fixture day, 12 examples, long).
- **Process:** Swift ran in one long-lived process with network access denied (`sandbox-exec`).
- **Order:** Python ran first, one process per input, straight before Swift; the Mac was on battery (67% → 57%) and warm from the back-to-back runs.

| Input | Runtime | First words | Whole brief | Reading tokens/s | Writing tokens/s | MLX peak | Recall | Unsupported | Instructions followed | Planted ranked urgent |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fixture day (2,998 tokens in) | Python | 19.0 s | 43.5 s | 159 | 21.3 | 3.92 GB | 5/5 | 0 | 0 | 0 |
| | **Swift** | 24.3 s | 50.2 s | 123 | 20.2 | 3.13 GB | **5/5** | **0** | **0** | **0** |
| 12 examples (1,204 tokens in) | Python | 7.6 s | 32.1 s | 159 | 22.1 | 3.54 GB | 2/2 | 0 | 0 | 0 |
| | **Swift** | 8.0 s | 33.9 s | 151 | 21.3 | 3.02 GB | **2/2** | **0** | **0** | **0** |
| Long (3,078 tokens in) | Python | 19.4 s | 46.9 s | 159 | 21.3 | 3.92 GB | 2/8 | 0 | 0 | 0 |
| | **Swift** | 22.5 s | 49.2 s | 137 | 20.3 | 3.12 GB | **2/8** | 1* | **0** | **0** |

\*"Sam Sample sent a notification with no text available": the fact check counts "sent" as an action a notification doesn't show. The item is accurate. This is the lexical check being strict, not an invented fact, and the evaluator was left unchanged.

**Load and memory:**
- **Load:** 2.43 s to a ready model (Python: 1.3–2.0 s plus 1.0–1.3 s for the import).
- **Process memory:** 3.36 GB after loading, 2.5–2.6 GB between briefs.
- **After the model was released in the same process:** 0.55 GB was still held (MLX reported 0.4 GB still active and nothing cached). Memory comes back completely only when the process exits.

**Reading:**
- **MLX Swift runs Qwen3.5-4B.** On these inputs it scores the same as Python. Its answers aren't word-for-word identical (they part after 400–620 characters, as the kernels' arithmetic differs slightly), but the rubric results match.
- **Speed is close.** Writing matches (20–21 tokens/s). Reading was 5–22% slower, and the first run was slowest, which is consistent with the Mac being warmer and on a lower battery than for the Python runs, and with first-use kernel loading. A cool-Mac re-run would settle it.
- **Swift used less memory** at its peak: 3.0–3.1 GB against 3.5–3.9 GB.
- **The ModelService should exit after it has idled,** not just release the model. Releasing inside the process left about 0.5 GB, and the idle budget is 300 MB for everything. That matches DESIGN's "loads on demand and exits to free RAM". The leftover 0.4 GB of active memory is worth one look in Stage 1, in case something still holds a reference.
- **Building needs** Xcode's Metal Toolchain component (839 MB, one-time) and `xcodebuild`; `swift build` can't compile MLX's Metal shaders. CI for the ModelService target must install the component.
- **Checkpoint 1, model part: passed.** Stage 1 keeps Qwen3.5-4B on MLX Swift; the fallbacks (Qwen3-4B, or one process per brief) aren't needed.

## 1.5: XPC routing and authentication (#67), 2026-10-09

`Prototype/xpc-spike/` builds a test app that registers two launch agents with `SMAppService`: a AegisCore stand-in (runs once at registration) and a ModelService stand-in that publishes a Mach service and is **not** started until a client looks it up. The app exits straight after registering, so everything below ran with the app closed. Synthetic jobs only (a timer, no model); all binaries signed ad hoc, each with its own signing identifier.

**Registration:** both agents came back `.enabled` straight away on this Mac; no Login Items approval was needed.

| Step | Default launchd throttle | `ThrottleInterval` = 1 s |
| --- | --- | --- |
| 1. Cold: Core's first job starts ModelService on demand (job takes 0.2 s) | 414 ms | 415 ms |
| 2. Warm: same process | 351 ms | 345 ms |
| 3. After ModelService exits on its own (idle 5 s), same connection | **2,412 ms** (launchd delayed the relaunch) | 405 ms |
| 4. ModelService killed mid-job | interruption reported to Core after 1.3 s (`NSXPCConnectionInterrupted`) | same |
| 5. Retry after the kill, same connection | **9,414 ms** (relaunch pushed to 10 s after the last launch) | 406 ms |
| 6. New connection | 354 ms | 355 ms |
| ModelService gone after its idle exit | yes | yes |

**Authentication** (`NSXPCListener.setConnectionCodeSigningRequirement` on ModelService, `NSXPCConnection.setCodeSigningRequirement` on Core):
- A client signed with another identifier was **refused** before ModelService's delegate saw it; the client got an error, no job ran.
- A client **ad hoc signed with Core's identifier was accepted.** Identifier-only requirements can be spoofed, so the real requirement must also pin the team: `anchor apple generic and certificate leaf[subject.OU] = "<team ID>"`. That needs the Apple Development identity this Mac doesn't have yet (#66).

**Decisions for Stage 1 (Checkpoint 1 input):**
1. **ModelService is its own on-demand `SMAppService` launch agent with a `MachServices` entry** (no `RunAtLoad`, no `KeepAlive`); AegisCore reaches it directly, with no app running. No embedded XPC service and no app broker (ChatGPT's research on this issue agrees).
2. **Set `ThrottleInterval` to 1 s** in ModelService's plist. With launchd's default, a relaunch within 10 s of the previous launch waits out the rest of the 10 s, so a crash costs up to about 9 s. Restart storms are prevented by Core's retry policy (backoff), not by launchd, because ModelService only starts when Core asks.
3. **ModelService exits on its own** after its last job (launchd never stops it), with a short idle grace so back-to-back live answers reuse the warm model: step 2.12's "exits within 10 s of finishing" stands.
4. **Core treats `NSXPCConnectionInterrupted` as retryable** on the same connection, with backoff and the job's deadline; the scheduler keeps the last valid brief if the retry fails.
5. **Both ends check code signatures**, with the team anchor once #66 provides a signing identity.

### 1.5b: signed with the owner's Apple Development team (#66), 2026-10-09

The same spike, rebuilt with the new Apple Development certificate. Each process builds its requirement from its own signature: `anchor apple generic and certificate leaf[subject.OU] = "<own team>" and (identifier …)`.

- **Both impostors are refused**, including the ad hoc one that copies Core's signing identifier (it was accepted in the ad hoc run).
- Everything else held with `ThrottleInterval` 1 s: cold start 413 ms, warm 274 ms, relaunch after the idle exit 358 ms, interruption reported after a kill, retry 362 ms, ModelService gone after its idle exit.
- **macOS remembers an agent's first signature.** Re-registering the agents under the same labels, now team-signed, made launchd kill Core at launch: "Launch Constraint Violation" (`OS_REASON_CODESIGNING`). The same build under fresh labels and bundle ID ran normally.

**Decision 6:** sign Aegis's app and agents with the team from the very first registration, and never register AegisCore or ModelService ad hoc, not even in a test. Changing an agent's signing team later needs new labels (or the owner resetting Background Items, which affects every app).

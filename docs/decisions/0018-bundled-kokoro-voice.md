# ADR-0018: Aegis includes its own Kokoro voice

**Status:** Accepted (owner's request; merged 2026-10-15, PR #243) · **Issue:** #221 · **Supersedes:** ADR-0015's external Voicebox dependency

## Context
The owner requested one integrated Aegis installation (2026-10-12). Voicebox's default Aegis preset uses Kokoro-82M, with `bm_george`. Running Voicebox's installed server invisibly still requires a separate app, its HTTP API, profiles and history.

## Decision
Use the native macOS KokoroCoreML package 0.11.2 (revision `6bfc02afb237a311caee927482e58c028edb6acb`), wrapped by the Mac-only `Packages/VoiceRuntime`. This uses Apple's CoreML and the same Kokoro model/preset without Python, an HTTP service, or the Voicebox app. AegisKit is unchanged. A new Mac-only `VoiceXPCProtocol` in SharedIPC defines prepare and synthesize before the client/service implementation. The native engine runs in `AegisVoice.xpc` inside Aegis.app, started automatically by NSXPCConnection; it is not a separate installation or launch agent. Both sides apply the existing same-team code-signing checks in signed builds. Package.resolved records transitive versions; only the library and BART G2P resources are linked, not the upstream CLI. Upstream code is unmodified; Apache-2.0 and attribution notices ship in the app.

`make app` downloads the public model archive `models-2026-03-23` at build time, verifies SHA-256 `0d24bbf80526456bd8640f9f484cd1c333aee8a936e618ac44e619eafb79aec9`, and bundles the two compiled models and George embedding. Speech only opens this bundle directory; missing/damaged assets select the existing system voice. The downloader API is never called at runtime. No text/audio is sent over a socket, written to files, or logged. Existing voice finishing, passage prefetch and on-device recognition stay in place.

Load on panel open. Serialize loading and generation inside the service. On close or cancellation, invalidate the XPC connection: the service exits, even during prediction, and macOS reclaims all model and CoreML cache memory. Parent exit/crash also disconnects it. Replies have a 30-second deadline; cancellation and late replies complete once and stale output is discarded. Generated audio remains in memory only. The app links only SharedIPC, keeping the engine out of the panel process. `make app` explicitly builds arm64, matching its Apple Silicon MLX model runtime; Kokoro also requires Apple Silicon Float16. An unavailable service uses the existing system voice. Synthetic tests cover close/reopen, cancellation, fallback, native synthesis, and actual service PID exit with bundled public model assets.

Mail continues using Apple's fetching process (ADR-0008). Launch it hidden and without activation, recover within the next minute after quit/wake, and leave user-opened windows alone. Tests inject the launcher and never read or launch real Mail.

## Consequences
One Aegis app now owns its voice and models. Voicebox profiles and custom voices no longer control Aegis; the existing George preset remains. App size increases by the bundled model and pronunciation resources. Model memory is used while the panel is open and is reclaimed by process exit on close. Direct in-process integration was tested and rejected: CoreML retained roughly 460 MB after close and grew on reload, violating the idle budget. The bundled-service smoke test verifies two synthesis/close/reopen cycles and that each service process exits. A future voice selector can use additional bundled embeddings; voice cloning and Voicebox's studio UI are outside this change.

Sources: [Voicebox's Kokoro backend](https://github.com/jamiepine/voicebox/blob/v0.5.0/backend/backends/kokoro_backend.py), [KokoroCoreML](https://github.com/Jud/kokoro-coreml/tree/v0.11.2), [model release](https://github.com/Jud/kokoro-coreml/releases/tag/models-2026-03-23).

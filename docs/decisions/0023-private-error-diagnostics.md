# ADR-0023: Private persistent error diagnostics

Status: implemented for owner testing, 2026-10-19. Issue #259.

The owner requests error history to diagnose intermittent voice failures. AegisApp writes a local JSONL journal at `~/Library/Logs/Aegis/diagnostics.jsonl`. Its API accepts a fixed code enum and optional integers only. Records contain timestamps, repetition counts, numeric technical details, process ID and a hash prefix of the app executable. Audio, transcripts, questions, collected content, names, handles, paths, arbitrary error descriptions and secrets cannot be supplied to the logger. Nothing is uploaded.

Writes use a utility queue, coalesce repeated codes over roughly 100 ms, and retain the last numeric details in each batch. The private directory uses mode 0700 and files 0600. A 2 MiB active file and three rotated files bound storage to about 8 MiB. There is no idle polling. Tests disable the default destination and use temporary invented fixtures.

Coverage includes capture/recognition/playback failures, app registration, Core/model refusals and source-health failures reported to the app, and cloud/task failures. A PID marker records an unclean exit on the next launch; an uncaught Objective-C exception gets a fixed code. This is not a universal crash recorder: abrupt termination may lose the last batch, background-only faults need to reach the app, and file-write failures fall back to code-only unified logging. macOS crash reports remain separate.

During an active post-wake utterance, up to 24 seconds of audio stay only in memory so slow recognizer setup cannot discard the question and an empty/failed result can retry once with the other on-device recognizer. Finalization, cancellation, panel closure and explicit conversation ending discard it. Idle input remains keyword-only; no new permission, public contract, third-party dependency or network path is introduced.

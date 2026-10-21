# Synthetic Python goldens for issue #60

`example-input.txt` is exactly `build_input(read_jsonl("Prototype/contracts/examples/events.jsonl"), ("2026-10-05T21:00:00Z", "2026-10-06T21:00:00Z")).text`, encoded as UTF-8 without a trailing newline, using default limits. The next-day weather event is outside that window.

`merge-cases.json` contains fixture seeds 7 and 42. For each seed, run `Fixtures.generate.generate.generate` into a temporary directory; concatenate its `expected/notifications.jsonl`, `expected/messages.jsonl`, and `expected/mail.jsonl` as `raw`; compute `merged` with `list(Prototype.pipeline.merge.merge_events(raw))`. This checks the same fixture twins as Python's reader integration test without requiring SQLite readers in Swift.

Both files contain only repository-generated synthetic data. Tests read these and the canonical examples/labels from the repo, as ContractTests does.

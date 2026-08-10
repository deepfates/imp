---
id: imp-6tg5
status: open
deps: []
links: [imp-6mls]
created: 2026-08-10T02:56:49Z
type: feature
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [observability, dashboard]
---
# Observatory: accrual architecture (per-run contracts, campaign ledger, durable events)

The v3 instrument is right for one run but pilot-hardcoded (18 cells, arm names, ±0.09 band, $40 budget, 1024 cap detection). For data accruing over time: (1) derive per-run parameters from the run root's contract.json (seeds, arms, ceilings, max_tokens, spend cap) so any campaign renders unmodified and the noise band belongs to the measurement config; (2) a campaign-ledger index view — one row per run root across tmp/matched_* and benchmarks/results/ (date, config fingerprint, spend, cells, per-arm delta vs its own noise band) so parity-over-time reads as a column of small multiples; (3) persist the feed's event stream to observatory-events.jsonl in the run root so live history survives restarts and replay is real rather than mtime-reconstructed.

## Acceptance Criteria

Dress-rehearsal root renders correctly with zero code edits; index page lists >=2 runs with per-arm deltas; events file written during a live run and replayed from disk.


## Notes

**2026-08-10T04:48:16Z**

Live-format decision made on the harness side (imp-6mls): runners will atomic-write run_root/live/*.json ledger snapshots; accrual architecture should treat those as the per-run live source and sealed/*.json as the durable record. Interim: observatory now parses dspy log lines into structured optimizer_points (pushed 2026-08-09) — that parsing becomes obsolete once snapshots exist.

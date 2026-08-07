---
id: imp-emrr
status: open
deps: []
links: [imp-g22q, imp-90uc, imp-pk5c]
created: 2026-08-07T17:07:55Z
type: bug
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [gepa, cache]
---
# Add config fingerprint to GEPA disk-cache key

disk.ex:242-255 keys entries on candidate text + example only — no model, params, metric, program structure, demos, adapter. :auto silently enables the disk cache whenever run_dir is set (config.ex:183-184). Reusing a run_dir after any config change replays stale scores; seed candidate always collides; self-checksums make contamination undetectable.

## Acceptance Criteria

entry_digest includes a config fingerprint (model id, params, metric identity, program structure); mismatched fingerprint invalidates or partitions the cache; test covering model-swap-same-run_dir.


## Notes

**2026-08-07T17:15:37Z**

SCOPE CORRECTION (adversarial review r2): GEPA never passes :cache_evaluation_storage — the Disk backend is reachable only via Optimize Anything run_dir. BUT the same weak candidate+example-only identity rides the CHECKPOINT: engine.ex:3396 dumps the in-memory cache into every checkpoint and load_cache (5352) replays it on resume. Widen this ticket to both backends: fingerprint the cache identity wherever it persists (disk backend AND checkpoint dump/load). For GEPA benchmark runs the checkpoint path is the live hazard.

**2026-08-07T17:58:48Z**

ON-PATH CONFIRMED (r5): same two-cache clarification as imp-g22q — evaluation cache (memory+checkpoint) live in campaign; identity fingerprint needed on the checkpoint dump/load path before any resumed Heavy result is trusted.

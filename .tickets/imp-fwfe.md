---
id: imp-fwfe
status: in_progress
deps: []
links: []
created: 2026-08-07T17:15:37Z
type: bug
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [gepa, budget, benchmarks, fairness]
---
# Budget parity: cache hits charge zero metric calls on resume

engine.ex:4307 records 0 metric calls on full cache hit; the cache is persisted into checkpoints (engine.ex:3396) and replayed on resume, so a resumed Imp arm re-scores prior candidates for free while the matched upstream arm may burn budget re-evaluating. Matched-budget fairness asymmetry — a resumed run's numbers cannot be called matched until upstream gepa v0.1.4 resume accounting is compared and either aligned or documented.

## Acceptance Criteria

Upstream resume accounting compared; Imp either charges parity or the delta is measured and disclosed in run evidence; test covering resumed-run budget accounting.


## Notes

**2026-08-07T17:58:48Z**

ON-PATH CONFIRMED (r5): Heavy resume is real (two stops recorded); zero-charge cache hits on resume (engine.ex:4307) apply to the actual campaign, pending upstream-accounting comparison.

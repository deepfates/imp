---
id: imp-fwfe
status: closed
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

**2026-08-09T07:00:56Z**

RESOLVED at 7e52298f: upstream comparison done by reading pinned gepa v0.1.4 source. In-run accounting is PARITY (both charge cache misses only — engine.py evaluate docstring). Across resume: genuine divergence (upstream state.py does not persist evaluation_cache; imp replays checkpointed cache free). Fix: GEPA resume_cache: :drop mirrors upstream; matched campaigns that resume must pass it — added to gepa014 preflight expectations alongside cache_identity (see imp-nbyg note). Load semantics tested both modes.

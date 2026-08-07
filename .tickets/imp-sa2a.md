---
id: imp-sa2a
status: open
deps: []
links: [imp-sqkr]
created: 2026-08-07T18:49:14Z
type: task
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [effectiveness, diagnosis, evidence]
---
# Diagnose historical optimizer misses as bug-or-benign

Under the parity worldview, past negatives are diagnostic signals, not evidence that optimization is an open question. Each gets a verdict: HotPotQA GEPA -0.015 (3 seeds, local model), Banking77 modeled-MIPRO missed preregistered bars, Grue zero-lift 3 seeds — all were single-arm absolute-lift runs on small local models with NO DSPy arm beside them. For each: would DSPy plausibly also show nothing under that exact config (benign — small-model/config limitation), or does tracing reveal an Imp fidelity defect (bug — fix before campaign)? Unexplained misses are the residual risk to a favorable outcome.

## Acceptance Criteria

Written verdict per historical negative with evidence (DSPy literature/replication or defect+fix commit); any 'bug' verdict has a filed blocking ticket; results linked from docs/EVIDENCE.md.


## Notes

**2026-08-07T18:49:30Z**

Depends conceptually on nothing; can start immediately and in parallel — its verdicts inform imp-u3af's prediction band.

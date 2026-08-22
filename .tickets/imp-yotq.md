---
id: imp-yotq
status: in_progress
deps: []
links: []
created: 2026-08-22T20:55:14Z
type: feature
priority: 0
assignee: deepfates
parent: imp-n8zn
tags: [ensemble, optimizers, composition]
---
# Land a natural ensemble lifecycle

Exercise Ensemble as an ordinary composition users would choose, with multiple independently useful or complementary programs and a meaningful reducer.

## Acceptance Criteria

A public Ensemble construction improves or robustly combines natural program behavior on a realistic dataset; subset/reducer/failure semantics are exercised; the composed program persists through trusted rebinding where callbacks require it and works in a fresh process.


## Notes

**2026-08-22T21:08:21Z**

Use the already retained BootstrapFewShot, SignatureOptimizer, and InferRules support-routing programs as three independently produced natural children. Construct a majority-vote Ensemble through the public API, evaluate it and each child on the held-out test split, then reconstruct trusted code and child Artifacts in a fresh OS process. This isolates the advertised composition capability without another optimizer search or benchmark campaign.

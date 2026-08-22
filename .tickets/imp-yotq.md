---
id: imp-yotq
status: closed
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

**2026-08-22T21:10:50Z**

Completed on first clean live run at e3e368f80178604d22ee3c2031f1dd295b2c7324. Public deterministic Ensemble composed retained BootstrapFewShot, SignatureOptimizer, and InferRules programs with a stable majority reducer. Held-out child scores 0.90/1.00/0.90; ensemble 1.00 versus live zero-shot 0.30, all 20 rows and zero errors. Fresh OS reconstruction loaded exact child Artifacts and scored 4/4. Main budget 81 single-attempt calls, 68556 input, 1718 output, $0.059145; fresh budget retained. Result: examples/optimizer_lifecycles/exercised-ensemble/result.json.

**2026-08-22T21:11:07Z**

Correction from retained-artifact test: the main run made 140, not 81, task transports: 20 baseline + 60 standalone child evaluations + 60 child calls inside the ensemble. Cost/token figures and all scores are unchanged.

---
id: imp-gbvu
status: closed
deps: []
links: []
created: 2026-08-10T12:33:17Z
type: parity
priority: 2
assignee: deepfates
parent: imp-yme4
---
# Implement modeled TPE for MIPROv2 parity beyond 9 trials

imp's MIPROv2 faithfully replicates only Optuna 4.9.0 TPE's startup phase and refuses >9 post-baseline objective trials (lib/imp/optimizer/mipro_v2.ex:1097 validate_search_fidelity) — an honestly-declared parity gap that stopped rehearsal take 8 at the source-faithful trials=18. The rehearsal proceeds matched at trials=9; the Heavy campaign cannot run paper-scale MIPROv2 until modeled TPE (the post-startup Parzen-estimator sampler, pinned to DSPy 3.2.1/Optuna 4.9.0 behavior) is implemented and differential-tested against the pinned Optuna. Discovered 2026-08-10 by the matched rehearsal's fidelity guard.


## Notes

**2026-08-22T13:38:48Z**

Resolved by the modeled Optuna/TPE implementation in commit 29210630 and current code. Imp now exposes :dspy_3_2_1_optuna_4_9_0, exercises startup plus the first Bayesian trial against pinned Optuna, covers checkpoint/resume and the public compile path, and runs a pinned minibatch trace through modeled TPE. The remaining floating-point tie boundary is documented in docs/internal/INSTRUCTION_OPTIMIZER_FIDELITY.md and is not the startup-only defect this ticket described. This establishes the defining mechanism, not broad live effectiveness; natural retained lifecycle acceptance is tracked by imp-n8zn.

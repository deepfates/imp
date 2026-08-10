---
id: imp-gbvu
status: open
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


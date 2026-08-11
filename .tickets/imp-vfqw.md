---
id: imp-vfqw
status: open
deps: []
links: []
created: 2026-08-11T06:06:03Z
type: benchmarks
priority: 1
assignee: deepfates
parent: imp-yme4
---
# optimizer_lift lane: imp MIPROv2 row is set up unfairly vs DSPy

lib/mix/tasks/imp.benchmark.optimizer_lift.ex compile_mipro/3 gives imp's MIPROv2 no proposal source: num_candidates 2 / num_trials 2 with program_aware/data_aware/tip_aware/fewshot_aware proposers all false and NO proposer LM. The DSPy side of the same row is driven by a provider-free deterministic LM that proposes the fixture's designed winner ('Always answer Paris when asked about France.'), which its trace confirms (instructions: ['Always answer Paris...']).

Measured consequence (provider-free, deterministic, repeatable): dspy baseline 0.0 -> optimized 1.0 (lift 1.0); imp baseline 0.0 -> optimized 0.0 (lift 0.0), candidate_count 2, best_score 0.0. Lane reports 9/10 rows passing and fails on this row.

This is a LANE FAIRNESS defect, not (on current evidence) an imp MIPROv2 defect: imp is asked to select an instruction it was never offered, while DSPy is handed it. The sibling rows do it correctly — COPRO passes extra_instructions, and both COPRO and GEPA now take explicit provider-free static proposer/reflection LMs (fixed in this same session).

FIX: give imp's MIPROv2 the same provider-free proposal source the DSPy side has, then re-run and see whether the row passes. If it still fails with a matched proposal source, THAT is a real imp defect and should be split into its own ticket with the artifact attached.

DO NOT close this by asserting the row passes without re-running the lane.


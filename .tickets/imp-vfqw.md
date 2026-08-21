---
id: imp-vfqw
status: closed
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


## Notes

**2026-08-11T14:17:20Z**

HYPOTHESIS FALSIFIED, DIAGNOSIS SHARPENED (2026-08-11).

My 'unfair setup' hypothesis was WRONG. The lane's own task LM already returns the planted winner when asked to propose (imp.benchmark.optimizer_lift.ex:703, 'Propose Imp instruction candidates' -> instructions: ['Always answer Paris when asked about France.']), and MIPROv2 falls back to the program's LM as :prompt_lm. I added an explicit prompt_lm anyway; result was identical (9/10 both before and after), so the change was neutral and I reverted it. imp was NOT short a proposal source.

WHAT IS ACTUALLY ESTABLISHED (provider-free, deterministic, repeatable):
- dspy MIPROv2: baseline 0.0 -> optimized 1.0 (lift 1.0)
- imp  MIPROv2: baseline 0.0 -> optimized 0.0 (lift 0.0), candidate_count 2
- imp's trial trace shows it DID select a non-default instruction: params {'atom:main:demos': 0, 'atom:main:instruction': 1}, yet the trial scored 0.0 and the compiled program scores 0.0 on the devset.
- The fixture LM answers 'Paris' iff the rendered prompt contains 'Always answer Paris' (should_answer_paris?/1, line 721). So a correctly APPLIED winning instruction is sufficient to score 1.0.
- This lane's stated purpose (moduledoc) is exactly 'given an injected winning instruction/demo, Imp optimizers select and apply it identically to DSPy 3.2.1 (lift_gap <= 0.001)'. So this row failing is the lane detecting its own target condition.

REMAINING FORK — one of:
 (a) the instruction at index 1 is not the planted winner (proposal path returns something else), or
 (b) index 1 IS the winner but the selected instruction is not applied to the compiled program / not rendered into the prompt.
(b) would be a genuine MIPROv2 defect and the more serious outcome.

NEXT DIAGNOSTIC (cheap, no provider): after MIPROv2.compile in this lane, dump (1) the compiled program's effective instruction, (2) the instruction candidate pool by index, (3) the rendered prompt for one devset call. That distinguishes (a) from (b) immediately. Do not close this ticket on reasoning; close it on that dump plus a re-run.

**2026-08-21T03:22:22Z**

Falsified the suspected core MIPRO application defect. The provider-free fixture matched an obsolete proposer prompt, so both Imp proposal calls returned `invalid_proposal` and never offered the planted winner. Updated the fixture to the current proposer contract; `mix imp.benchmark.optimizer_lift` now passes 10/10 rows, including MIPROv2 0.0 -> 1.0. This is a benchmark integration defect, not held-out effectiveness evidence.

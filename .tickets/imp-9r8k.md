---
id: imp-9r8k
status: closed
deps: []
links: []
created: 2026-08-22T20:55:14Z
type: feature
priority: 0
assignee: deepfates
parent: imp-n8zn
tags: [instruction, optimizers, live]
---
# Land useful instruction and rule optimization

Replace the remaining stopped or neutral instruction/rule stories with ordinary successful lifecycles for SignatureOptimizer and InferRules; canonize COPRO's already useful retained result using correct replay semantics.

## Acceptance Criteria

Natural live proposals or rules improve a separately selected task without hidden answers; selected parameters reload in fresh trusted code and execute usefully; budgets, failures, costs, and reports remain observable. COPRO's existing 0.475 to 0.55 held-out result is accepted once artifact identity and error-free fresh execution are verified without requiring stochastic provider bytes to be identical.


## Notes

**2026-08-22T20:55:25Z**

Primary-evidence disposition at start: retained COPRO V2 naturally mutated the instruction and improved held-out accuracy 0.475 -> 0.55 with zero parse errors. Its fresh process loaded and served the exact selected Artifact, but one of forty stochastic MLX predictions differed; byte-identical provider output is not a valid persistence requirement. Credit COPRO after verifying artifact identity and useful/error-free replay. Remaining capability work is SignatureOptimizer (only retained run stopped at a malformed proposer boundary) and InferRules (source-protected run selected a 0.625 tie, no useful rule).

**2026-08-22T21:02:58Z**

First clean live acceptance at 422b70ca ran both optimizers with real OpenRouter task/proposer models. SignatureOptimizer selected at 0.95 on the separate selection split. InferRules completed two real proposal calls, four candidates, zero bootstrap errors, and selected at 1.0, but failed the required untouched-test improvement over the 0.40 baseline. This is a treatment-level red, not a mechanism failure. The runner then exposed its own diagnostic defect: it asserted before writing result.json, losing final scores/budgets although both private parameter Artifacts survived. Move receipt persistence before the acceptance assertion; rerun only as an instrumentation repair or use a newly justified treatment, never silently call the first run green.

**2026-08-22T21:07:08Z**

Completed at clean source a24a408660eaff7ac9b4ed2cd8691c5a177f8cf3. Exact instrumentation-repair rerun used shipped 20/20/20 support-routing splits, OpenRouter GPT-5.4 Mini task LM and Claude Sonnet 4.6 proposer. Baseline selection/test 0.50/0.30. SignatureOptimizer selected/test 1.00/0.95; InferRules 1.00/0.90; zero row errors. Exact private parameter Artifacts loaded into fresh OS BEAMs and both scored 4/4. Main task budget 288 calls, 120631 input, 3297 output, $0.105325; optimizer budget 5 calls, 3933 input, 1742 output, $0.037929; fresh budgets retained separately. Result and artifacts are under examples/optimizer_lifecycles/exercised-instruction/. COPRO is separately credited by its retained 0.475->0.55 held-out V2 and exact Artifact fresh application; one stochastic prediction difference is not a persistence failure.

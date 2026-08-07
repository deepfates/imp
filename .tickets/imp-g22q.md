---
id: imp-g22q
status: open
deps: [imp-90uc]
links: [imp-emrr, imp-90uc, imp-pk5c]
created: 2026-08-07T17:07:55Z
type: bug
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [gepa, cache, correctness]
---
# Extend :complete? cache guard to GEPA ProgramAdapter and per-example path

The :complete? completeness convention (engine.ex:4470-4473) is honored by Optimize Anything's batch evaluator but never extended to GEPA's ProgramAdapter (program_adapter.ex:88-92 sets only metric_calls/failures) and adapter.ex:238 passes record_completeness?: false. Timeout-killed 0.0s (imp-90uc) are unclassified, so they get durably cached as complete evaluations and replayed on resume — permanent score corruption.

## Acceptance Criteria

ProgramAdapter sets complete?: failures == 0; per-example path records completeness; resume test proving a timeout-killed row is re-evaluated, not replayed.


## Notes

**2026-08-07T17:58:48Z**

ON-PATH CONFIRMED (r5): the r2 'cache: false neutralizes it' concession conflated two caches. run_imp.exs cache: false = LM request cache (ReqLLM). The EVALUATION cache defaults on (gepa.ex:124 cache_evaluation: true) and the campaign never overrides it; Heavy threads checkpoint_fn/resume_state (gepa_study_condition.ex:114) and has already stopped twice. Checkpoint replay of unclassified 0.0s is the campaign's actual operating mode on resume. Gates the campaign.

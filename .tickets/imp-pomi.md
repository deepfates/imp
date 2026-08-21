---
id: imp-pomi
status: closed
deps: [imp-88sn]
links: []
created: 2026-08-07T18:49:30Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [docs, evidence, narrative]
---
# Canonize the release evidence and its limits

Make the public story match what a user can actually do at the release commit.
The null expectation for a faithful DSPy port is that central prompt optimizers
work under comparable treatment, so unexpected deficits trigger diagnosis; it
is not legitimate to declare every negative an implementation defect without
classification. Canonize the core packaged lifecycle, current positive TREC and
Optimize Anything evidence, valid Banking77/HotPot negatives, and open matched
breadth. Remove stale chronology and invalid parity language through the claims
registry rather than drive-by prose.

## Acceptance Criteria

README, docs/EVIDENCE.md, case studies, archive READMEs, claims registry, and
generated conformance surfaces agree on the exact current results and scopes;
every public claim identifies whether it is implementation, exercised behavior,
scientific evidence, or open uncertainty; stale take-8/take-11 and pre-OA status
is removed or explicitly superseded; claim-drift checks pass at the release
commit.


## Notes

**2026-08-09T07:20:39Z**

CORRECTION for the reframe: earlier framing 'single-arm absolute-lift runs on small local models' is wrong for HotPotQA and Banking77 (GPT-5.4-mini/Sonnet-4.6 via OpenRouter); only Grue was local. The accurate story per docs/EVIDENCE.md verdicts: configs whose budgets/test-granularity/ceilings could not resolve paper-sized effects — Banking77 was actually POSITIVE both times, just under the preregistered bar. Use the EVIDENCE.md table as source of truth.

**2026-08-21T05:33:18Z**

2026-08-20 canonization complete. The claims registry now asserts the admitted schema-v2 three-class Optimize Anything C3 result at its exact GPT-5.4-mini/evaluator scope (+0.254759 retry code, +0.518609 agent config, +0.059774 scheduling mean untouched-test lift; improving seeds 3/3, 3/3, 2/3; 44 calls/$0.082421) while leaving upstream comparative/paper-scale OA open. The generated conformance source/report, coverage matrix, research portfolio, and claim tests were updated consistently; the completed OA claim was removed from unfinished research ownership. docs/EVIDENCE.md now classifies HotPot JSON-GEPA as a scientific negative for its exact treatment, Banking77 as a scientific negative against its preregistered >=0.05 bar despite small positive lift, Grue as unresolved/no-signal, and IFBench scorer drift as a fixed product/integration defect. Take 11 is described as six completed optimization/selection cells and no held-out verdict; Addendum 7 is visibly marked historical and superseded by Addendum 10, and the archive README already withdraws the incomparable selection figures. Current tutorial claims point to the new content-addressed three-repeat live/fresh-service artifact. Regenerated projections and targeted claim/dashboard/upstream tests pass; final mix fast.check: 53 doctests, 9 properties, 2,756 tests, 0 failures, 10 skipped.

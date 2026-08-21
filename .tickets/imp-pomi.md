---
id: imp-pomi
status: open
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

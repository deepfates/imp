---
id: imp-pomi
status: open
deps: []
links: []
created: 2026-08-07T18:49:30Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [docs, evidence, narrative]
---
# Reframe evidence narrative around the parity worldview

README/EVIDENCE currently present historical negatives without config context, reading as 'optimizer effectiveness is an open question.' Corrected worldview: DSPy/GEPA/MIPRO are published, replicated results — parity is the null hypothesis for a faithful port; the negatives were single-arm absolute-lift runs on small local models with no DSPy arm (the one true matched head-to-head, TREC, was favorable). Reword the evidence narrative to state expectations honestly: parity expected, deficit = implementation defect, benchmark = confirmation. Must go through the claims-registry/claim-drift machinery, not drive-by prose edits.

## Acceptance Criteria

README evidence section and docs/EVIDENCE.md state the parity frame with per-result config context; claims registry updated consistently; claim-drift checks pass.


## Notes

**2026-08-09T07:20:39Z**

CORRECTION for the reframe: earlier framing 'single-arm absolute-lift runs on small local models' is wrong for HotPotQA and Banking77 (GPT-5.4-mini/Sonnet-4.6 via OpenRouter); only Grue was local. The accurate story per docs/EVIDENCE.md verdicts: configs whose budgets/test-granularity/ceilings could not resolve paper-sized effects — Banking77 was actually POSITIVE both times, just under the preregistered bar. Use the EVIDENCE.md table as source of truth.

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


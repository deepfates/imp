---
id: imp-2kyx
status: in_progress
deps: []
links: []
created: 2026-08-10T18:24:10Z
type: ifbench
priority: 0
assignee: deepfates
parent: imp-yme4
---
# Run the source-faithful matched rehearsal to terminal and publish the verdict

The 16k rehearsal (examples/matched_ifbench_rehearsal16k) is the campaign that answers whether imp's optimizers match pinned DSPy at the benchmark authors' own settings (16384 output tokens, ~1/3-paper budgets, 1 seed, $60-65 envelope). State 2026-08-10: ten launches, all ten stops harness defects (documented as PREREGISTRATION addenda 1-9, roots archived to evidence/matched/); take 11 running detached. ESTABLISHED so far: GEPA selection-set parity (take 8, imp 0.8542 vs upstream 0.8698 champions) + full trial ledgers; imp MIPROv2 fidelity boundary found (<=9 Optuna-startup trials, ticket imp-gbvu) and both arms matched at 9. REMAINING: a terminal run producing all 6 sealed cells including the held-out barrier (64 novel-constraint rows/arm), then the verdict written against PREREGISTRATION P1/P2/P3 with paired analysis, an evidence archive, and docs/EVIDENCE.md updated from target to measured.

## Acceptance Criteria

One take reaches terminal with 6 sealed cells and both complete result artifacts; verdict addendum written against P1/P2/P3 including held-out paired analysis; run root archived to evidence/matched/ with checksums; docs/EVIDENCE.md + README reconciled to the measured outcome.


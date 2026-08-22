---
id: imp-n8zn
status: in_progress
deps: [imp-0du1, imp-nenu]
links: []
created: 2026-08-22T13:38:01Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [optimizers, live, artifact]
---
# Exercise every advertised optimizer through a natural retained lifecycle

Make each advertised optimizer family accomplish a meaningful task through the ordinary public API. Use natural provider proposals, mutations, gradients, examples, or training as the defining mechanism requires; separate training, selection, and untouched evaluation; retain the selected state; and prove that state works after reload in fresh trusted code. This is product acceptance, not a demand that every treatment produce a positive scientific result.

## Acceptance Criteria

Every publicly advertised optimizer family has at least one credible successful user story suited to its defining mechanism; the story uses ordinary package APIs and natural live behavior rather than planted or canned winning outputs; data barriers are explicit and disjoint where learning occurs; budgets, failures, parse errors, reports, and actual costs are observable; Artifact or the appropriate value/weight artifact roundtrips into a fresh program or service; failed treatments are retained and classified honestly but do not alone satisfy the family; and any missing defining mechanism is repaired as a product defect rather than hidden behind an artificial bound. An integration that cannot meet this standard may remain explicitly research-only, but it is not advertised as a completed product optimizer.

## Notes

**2026-08-22T20:52:47Z**

Classical demonstration tranche completed on clean commit f21a456f9f2be7066251640dbeeab02a3d0f7ff4 with the ordinary live support-routing program and disjoint 20/20/20 rows. Untouched baseline 0.40; BootstrapFewShot 0.90, RandomSearch 0.95, KNNFewShot 0.60; zero errors. Exact retained states loaded in fresh OS BEAMs and scored 1.00/1.00/0.75 on four probes. Main budget: 423 single-attempt transports, 159,669 input, 5,734 output, USD 0.145534; fresh ledgers retained separately. The run falsified two persistence assumptions before success: BudgetedLM is intentionally nonportable, and KNN's metric requires trusted registry rebinding. It also found and fixed a real Imp.save! defect: whole-program artifacts were mode 0644 while containing demos; Saving now uses exclusive synced mode-0600 temp files plus atomic replacement, with regression coverage. Runner, result, and all three validated artifacts live under examples/optimizer_lifecycles/. This satisfies BootstrapFewShot, RandomSearch, and KNNFewShot; LabeledFewShot is separately satisfied by the current clean live tutorial.

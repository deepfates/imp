---
id: imp-sqkr
status: open
deps: [imp-fkwy]
links: [imp-sa2a]
created: 2026-08-07T18:49:14Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [fidelity, differential, benchmarks, readiness]
---
# Green fidelity differentials at the campaign HEAD

Parity with DSPy is the null hypothesis for a faithful port; the strongest pre-run predictor of a favorable matched result is arm-to-arm differential tests (real pinned DSPy 3.2.1 sidecar) passing at the exact commit the campaign runs from. These exist (adapter golden traces, few-shot/weight optimizer differentials, MIPRO/SIMBA structural cases) but nothing gates the campaign on their being green at HEAD — and HEAD has zero CI provenance (imp-fkwy).

## Acceptance Criteria

All differential/conformance suites executed at the campaign commit with results recorded as evidence; any red differential is a filed defect blocking launch.


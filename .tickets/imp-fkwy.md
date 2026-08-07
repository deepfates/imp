---
id: imp-fkwy
status: open
deps: []
links: []
created: 2026-08-07T17:19:00Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [ci, release, provenance]
---
# Restore CI provenance: push main, green the pipeline before paid runs

Local main is 583 commits ahead of origin; last CI run on origin main 2026-07-24 — every benchmark-fidelity repair at HEAD has zero CI provenance. No branch protection (gh api 404) so CI is advisory even when it runs. Scheduled Evidence lane failed on 2026-07-27 and 2026-08-03, untriaged; two dependabot CI runs also red. The audited HEAD is CI-unverified code.

## Acceptance Criteria

main pushed; CI green at the commit the benchmark campaign runs from; Evidence lane failures triaged to green or the lane's claims withdrawn; branch protection decision recorded.


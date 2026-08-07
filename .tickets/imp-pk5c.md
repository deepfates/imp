---
id: imp-pk5c
status: open
deps: []
links: [imp-g22q, imp-emrr, imp-90uc]
created: 2026-08-07T17:07:55Z
type: bug
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [evaluation, correctness]
---
# Fix :deadline silently discarding per-row :timeout

evaluate.ex:374-387 and trajectory.ex:1112-1148 (never receives the timeout variable) let one hung row consume the entire remaining deadline, starving later rows into {:exit, :timeout}.

## Acceptance Criteria

Wave calls use min(remaining_deadline, per_row_timeout) with :infinity handling; combined timeout+deadline test.


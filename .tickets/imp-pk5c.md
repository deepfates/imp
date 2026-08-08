---
id: imp-pk5c
status: closed
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


## Notes

**2026-08-08T00:47:00Z**

DONE: min(timeout, remaining) in both wave paths (evaluate.ex evaluation_stream, trajectory.ex run_until_deadline which now receives the timeout); combined tests prove a hung row dies at ~timeout while later rows complete within deadline.

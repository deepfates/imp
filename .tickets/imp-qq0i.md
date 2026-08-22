---
id: imp-qq0i
status: closed
deps: [imp-xct8]
links: []
created: 2026-08-22T15:39:33Z
type: feature
priority: 1
assignee: deepfates
parent: imp-nenu
tags: [playbook, optimizer, product]
---
# Expose an ordinary challenger-to-promotion playbook lifecycle

Turn the existing strong Playbook optimizer machinery into a coherent public workflow: bind, inspect, propose/evolve, evaluate a challenger, promote or reject, persist, restore, and audit. Preserve Imp split discipline and rollback rather than copying Ax automatic mutation.

## Acceptance Criteria

A user can evolve a playbook from observed failures through one documented public lifecycle with bounded proposals, separate promotion and audit data, explicit challenger review, exact rollback, usage/cost reporting, persistence and fresh restore; executable tests cover accepted and rejected evolution, failure clustering or equivalent grounded weakness selection, and no silent production hot-promotion.


## Notes

**2026-08-22T20:28:33Z**

Completed the ordinary public lifecycle. The existing optimizer already enforced typed atomic deltas, train/promotion/audit disjointness, content and provenance leakage gates, bounded retained growth, stage reservations, aggregate usage, promotion plus audit lift, exact rejection, rollback, and integrity-bound restore. Added only the missing consumer seams: grounded observed_weaknesses/2 for proposer review, compact review/1, private atomic completed-checkpoint write/read, explicit no-hot-promotion documentation, and an API Guide workflow. Executable coverage proves accepted and rejected challengers, grounded training-only weakness selection, usage/reasons, mode-0600 disk persistence, fresh-runtime restore, tamper/baseline refusal, and byte-identical rollback. Focused optimizer/contract/public/package tests pass.

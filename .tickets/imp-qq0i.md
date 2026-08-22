---
id: imp-qq0i
status: open
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


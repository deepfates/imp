---
id: imp-iget
status: open
deps: [imp-xct8]
links: []
created: 2026-08-22T15:39:33Z
type: feature
priority: 0
assignee: deepfates
parent: imp-nenu
tags: [agents, optimizer, tools, safety]
---
# Optimize an executed agent safely through the ordinary Imp lifecycle

Build the real agent user story over existing ReAct/RLM/composed programs and optimizer machinery: action-aware task records and run reports, side-effect-safe evaluation, separate selection/test, selected component Artifact, and fresh operation. This replaces any implication that the JSON agent_config OA result proves actual Imp agent optimization.

## Acceptance Criteria

A public example optimizes an actually executed ReAct, RLM, or composed tool program against task outcomes plus expected/forbidden actions, completion, errors, turns, usage, and traces; tool effects use replay or sandbox by default and live execution fails closed unless explicitly authorized; learned work keeps disjoint selection/test; the selected Artifact applies to reconstructed trusted code and runs after a fresh process restart; a bounded natural live treatment succeeds meaningfully and failures/costs remain inspectable.


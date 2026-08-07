---
id: imp-zc94
status: open
deps: []
links: []
created: 2026-08-07T17:13:23Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [agents, react, dspy]
---
# Decide ReAct error-recovery semantics vs DSPy

Imp ReAct fails fast on tool errors; DSPy feeds the error back as an observation so the model can recover. Materially changes agent behavior; migrating DSPy agents that rely on recovery silently break. CONFORMANCE documents the divergence but the migration mapping table does not flag it.

## Acceptance Criteria

Either an opt-in observe-and-continue mode with tests, or a loud migration-table warning; benchmark configs state which semantics ran.


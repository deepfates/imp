---
id: imp-xct8
status: open
deps: []
links: []
created: 2026-08-22T15:39:33Z
type: feature
priority: 0
assignee: deepfates
parent: imp-nenu
tags: [optimizer, components, agents]
---
# Generalize Imp programs into validated optimizable components

Unify the existing ProgramParameters lenses and GEPA ProgramAdapter behind one program-owned component protocol spanning predictor instructions/demos/config, tool descriptions/schemas, playbooks, and custom agent/program stages. Preserve stable IDs, JSON-safe values, constraints/dependencies, digest guards, validation, pure atomic application, and trusted runtime callbacks.

## Acceptance Criteria

Ordinary public programs can enumerate described typed optimizable components and atomically apply validated changes; existing predictor GEPA and Artifact behavior remains compatible; ReAct/RLM/composed custom modules can expose non-secret non-effectful components without serializing handlers, tools, credentials, or policies; executable tests prove identity, dependency/constraint validation, rollback on any invalid change, Artifact roundtrip, and fresh trusted application.


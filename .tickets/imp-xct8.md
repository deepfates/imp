---
id: imp-xct8
status: in_progress
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

## 2026-08-22 implementation state

The shared component boundary is implemented: public
`Imp.Optimizer.Component` descriptions wrap the existing JSON-safe Parameters;
`Imp.ProgramParameters.components/1` owns built-in predictor, playbook, ReAct
tool, and custom-module enumeration; paired batch callbacks expose arbitrary
consumer components; constraints and acyclic dependencies are enforced before
any callback; generalized parameter artifacts apply to fresh trusted code; and
GEPA instruction candidates use the same atomic digest-guarded change path.
Structured Optimize Anything candidates can now execute through complete
component value maps and export the selected state through the same parameter
Artifact boundary. The compatibility, public-surface, and package suites are
green.

Do not close this ticket from those mechanics alone. The remaining acceptance
proof is an ordinary action-aware ReAct/RLM or composed consumer lifecycle that
uses these components through real optimization, held-out selection, Artifact
reload, and fresh execution. The isolated ACP runtime branch owns ReActV2/RLM
event and cancellation edits; integrate that seam before choosing the smallest
non-conflicting consumer proof.

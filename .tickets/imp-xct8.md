---
id: imp-xct8
status: closed
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

Commit `788c971c` supplied the missing ordinary consumer proof: a packaged
ReActV2 program used natural Optimize Anything proposals, disjoint selection
and held-out rows, action-aware scoring, a parameter Artifact, and fresh trusted
execution. The exact result is recorded below and in `docs/EVIDENCE.md`.
External-effect authorization remains separate work in `imp-iget`; it is not a
missing part of this component protocol.

## Notes

**2026-08-22T19:33:01Z**

2026-08-22: The missing ordinary consumer now exists diagnostically on the current dirty tree: a packaged ReActV2 support program exposes three tool descriptions through the shared component protocol; natural Optimize Anything proposals select on disjoint rows; held-out action-aware scoring improved 0.90 to 1.00; the parameter Artifact ran at 1.00 in a fresh BEAM with reconstructed trusted tool functions. The run also falsified two treatment assumptions before succeeding: GPT-5.4 Mini rejected an unsupported temperature under strict OpenRouter routing, and the evaluator initially awarded partial credit to prediction_error/no-action results. Both were repaired, and a provider-free package test now proves description application preserves trusted callbacks and executes the intended sandbox action. This remains diagnostic until the exact clean code commit is rerun and durably admitted; do not close from the dirty result.

**2026-08-22T19:37:38Z**

2026-08-22 exact clean proof: commit 788c971ce761b25ed6533bc179765d985b17d0fc completed the packaged natural ReActV2/OA lifecycle. Held-out action-aware mean improved 0.95 -> 0.975 on four untouched rows; the baseline's extra account lookup before refund disappeared; the selected Artifact applied to reconstructed trusted tools in a fresh BEAM and scored 1.0. Provider-free package/example tests pass. Separate hard-capped budgets recorded 77 task + 3 reflection requests, about USD 0.0744 total. This fulfills this ticket's component-protocol acceptance; broader external-effect authorization remains imp-iget work.

---
id: imp-nenu
status: in_progress
deps: [imp-xct8, imp-iget, imp-qq0i]
links: []
created: 2026-08-22T13:37:48Z
type: feature
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [optimize-anything, ax, semantics]
---
# Audit contemporary Optimize Anything and Ax product semantics

Pin and study the current relevant Optimize Anything and Ax sources, documentation, tests, and representative examples. Inventory the user-visible concepts that belong in Imp's intended product, distinguish valuable semantics from Python/TypeScript-specific shape, and implement or explicitly disposition every material opportunity. Ax is a useful independent semantic comparator, not scientific authority for DSPy parity.

## Acceptance Criteria

The audit records exact upstream versions and primary-source coordinates; every material user-facing concept is classified as implemented idiomatically in Imp, deliberately represented by a stronger BEAM-native alternative, explicitly downstream/experimental, or a concrete missing capability; adopted concepts have ordinary public API coverage and executable semantic probes; public documentation explains consequential differences; no item is dismissed merely because its source-language shape differs.

## Notes

**2026-08-22T15:39:33Z**

2026-08-22 exact GEPA v0.1.4 and Ax 24.0.4 audit: OA is substantially represented; the central gap is coherence. Imp.ProgramParameters can persist predictor instruction/demo/config, playbook, and ReAct tool parameters, but GEPA ProgramAdapter derives only predictor-instruction components; Imp.Agent is not an optimizable Imp.Module; the positive OA agent_config result optimized a JSON routing policy, not an executed Imp agent. Adopt Ax value semantics, not JS shape: one validated generic component tree with stable identity/kind/value/description/constraints/dependencies and pure application; action-aware evaluation of actual ReAct/RLM/composed runs; replay/sandbox by default for side-effecting optimizer evaluation; ordinary selected-artifact/reload agent story; ergonomic playbook challenger/promotion/audit lifecycle. Refresh Ax authority from obsolete local 23.0.3 to exact npm 24.0.4 gitHead a366e497 and tarball SHA256 48f56c09. Defer context maps, flow DSLs, bindings, and unreleased GEPA main engines.

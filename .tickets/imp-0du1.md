---
id: imp-0du1
status: in_progress
deps: []
links: []
created: 2026-08-21T04:50:53Z
type: feature
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [dspy, parity, upstream]
---
# Audit and implement the current stable DSPy semantic delta

Imp's existing conformance baseline predates current stable DSPy. Classify the current public DSPy documentation and exported code by observable user semantics, then implement or explicitly bound material gaps in the shared program/evaluate/optimize/deploy loop. Prioritize central semantics over Python mechanics and over downstream experimental breadth.

## Acceptance Criteria

A source-pinned current-stable inventory covers LM/configuration, signatures/adapters, Predict and composed Module behavior, tools/ReAct, evaluation, prompt optimizers, save/load, async/streaming/cache/usage, and production entry points; every material difference has an executable differential or an explicit intentional BEAM disposition; central supported paths are implemented and exercised through Imp's public API; experimental code/weight optimization is classified downstream and cannot substitute for prompt-program parity.


## Notes

**2026-08-22T13:39:54Z**

The owner ratified this as the first source-grounded dependency of the larger release objective on 2026-08-22. The current released target is DSPy 3.3.1 at peeled tag commit 638e155cf725236fe5d01b5332394a7bc128881d; 3.3.0 is now a predecessor, not the completion target. Complete the material stable inventory from the exact pinned source, docs, tests, examples, and release delta. Treat symbol presence as insufficient: every material user capability needs an executable semantic differential, a tested BEAM-native alternative, an explicit downstream/experimental disposition, or an owned implementation gap. Inspect current main for important fixes and impending concepts, but do not silently turn unreleased churn into a stable compatibility requirement.

**2026-08-22T15:37:49Z**

2026-08-22 exact-source audit against DSPy 3.3.1 commit 638e155c found the current evidence authority stale: setup_reference_test_env.sh and verify_dspy_current_target.py still require 3.3.0b1, while upstream_fidelity still treats 3.2.1/beta as current. Dependency order from primary code/tests: (1) repin/provision exact 3.3.1 authority; (2) implement shared missing-output defaults across Chat, JSON, XML, and ReActV2 submit; (3) replace old regex/top-level XML behavior with 3.3.1 nested XML semantics; (4) add MCP text/structured result normalization preserving explicit null/false/0/empty values and error-before-conversion; (5) rerun exact-stable differentials over otherwise-strong ReActV2/RLM/evaluation/GEPA/MIPRO/save-load/cache/usage/streaming; (6) prove resource-loading cannot be triggered by parsed/model data; (7) own experimental Flex/typed-LM/SandboxSerializable dispositions separately. Provider-free audit ran 99 focused tests, all passing; those prove current mechanisms, not the accepted stable target.

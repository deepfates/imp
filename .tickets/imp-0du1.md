---
id: imp-0du1
status: open
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


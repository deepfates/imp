---
id: imp-yme4
status: in_progress
deps: []
links: []
created: 2026-07-25T16:21:13Z
type: epic
priority: 0
assignee: deepfates
tags: [dspy, parity, optimizers, gepa, optimize-anything, product]
---
# Make Imp's advertised DSPy semantics real

Carry Imp from its large implemented surface and conflicting evidence systems to honest semantic parity with DSPy and the useful surrounding ecosystem, while keeping Elixir-native equivalents where Python mechanics are incidental. Dashboard work is supporting infrastructure, not the endpoint; fix or remove facades by exercising the actual behavior users depend on.

## Acceptance Criteria

For every public surface advertised in the README and Imp-for-DSPy mapping, the repository identifies the upstream semantic contract and demonstrates either reproducible behavioral/differential parity or an explicit superior BEAM-native equivalent. Core declaration, execution, adapters, modules, evaluation, retrieval/tool/agent composition, persistence/operation, and optimizer families are usable from an ordinary consumer project. GEPA, Optimize Anything, MIPROv2/SIMBA/COPRO, bootstrap/random-search families, and any other advertised optimizer have meaningful held-out task outcomes rather than structural smoke alone; matched comparisons state model/provider/cost/seed/splits and disagreements. One killer end-to-end optimization example shows material improvement on unseen data and leaves an inspectable reusable program artifact. Generated conformance, claims, docs, and executable dashboards agree from a clean checkout. Missing upstream features stay visibly open; package or release readiness alone cannot close this epic.

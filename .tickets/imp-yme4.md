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

## Notes

**2026-07-25T16:27:40Z**

2026-07-25 deterministic-truth slice: the committed-evidence dashboard at current HEAD computes 10 proven / 26 blocked / 19 informational, profile_ready=false. Restored docs/EVIDENCE.md to those honest counts and moved the venv-free reconciliation regression into the normal test suite so fast.check catches future prose drift; ephemeral lane directories remain replaced by fresh empty temp paths in the test, so local tmp state cannot promote claims. No evidence was made proven. Focused Mix execution was unavailable because the sandbox forbids Mix.PubSub TCP sockets and the escalation was aborted; git diff --check and the current dashboard JSON were verified. Epic remains open for semantic parity.

**2026-07-25T16:28:25Z**

Principal verification after f1e05c8: mix test test/evidence_reconciliation_test.exs passed 1 test, 0 failures in 1.2s under the ordinary exclusion set, confirming the regression now runs despite evidence_infrastructure being excluded.

**2026-07-25T18:31:00Z**

Principal semantic-parity checkpoint. Recovered and retained the existing authority hierarchy instead of adding another matrix: claims.json is the claim ledger; authorities.json pins upstream identity; reproductions.json maps surfaces/protocols/admitted tiers; generated CONFORMANCE.md and maintainer reproductions/authority pages are projections; COVERAGE_MATRIX, PARITY_VALIDATION_PROGRAM, BENCHMARK_TRUTH, and specialized fidelity notes add human context but cannot override the machine chain. Commits 927cd8e, 1f653ad, 7e64feb, e358ee8, 0169333, and ec250e9 respectively repaired immutable artifact admission, independently admitted the narrow GEPA v0.1.4 structural contract, made `with_lm`/`with_demos` traverse complete executable graphs, preserved typed SIMBA reflection inputs, rejected no-op generic instruction optimization, and implemented native DSPy 3.2.1 InferRules induction with an exact provider-free differential.

Optimize Anything C3 audit found that immutable artifact 58ff84ac selected candidates and computed final scores on the same development set. The artifact remains exact T2 live-execution evidence but its C3 claim is now a telos target. Schema v2 implements pairwise-distinct train/selection/test datasets for code, agent configuration, and scheduling; passes only on multi-seed test lift; selects the displayed representative by selection score; and requires the pure provenance/accounting validator before the dashboard can accept full evidence. Focused optimizer/evidence execution passed 46 tests with zero failures, including the stubbed three-family live campaign; `mix reproduction.check` passed. The full default suite then passed 53 doctests, 9 properties, and 2,268 tests with zero failures and 11 skips. No schema-v2 provider campaign has been run or admitted, so Optimize Anything effectiveness remains open. GEPA 9dbefc4 remains preserved and independently verified only as structural conformance, not effectiveness. The epic remains open for held-out optimizer outcomes, remaining public facades, and broad package-consumer exercise.

**2026-07-25T18:41:30Z**

LabeledFewShot user-semantics slice: restored DSPy 3.2.1's sampled `k=16`, seed-zero defaults; added the ordered `sample: false` path and explicit integer `seed:`; clears stale demos; and applies separate no-replacement draws from one advancing stream to every optimizer-exposed predictor. Imp deliberately uses serializable BEAM optimizer RNG state rather than Python `random.Random`, so exact equal-seed subset ordering is excluded while determinism, no replacement, traversal, and ordered selection are preserved. The tutorial and its runner now explicitly select `sample: false`, which names the ordered behavior used by the immutable live artifact instead of relying on the former Imp default. Conformance classifies the family as an Elixir-native equivalent and keeps held-out family effectiveness open. Focused source/docs/conformance/package execution passed 61 tests with zero failures; the existing provider-free optimizer differential passed 10/10 rows and directly matched the explicit ordered LabeledFewShot comparison. Exact Python RNG-sequence parity and general LabeledFewShot effectiveness remain unclaimed.

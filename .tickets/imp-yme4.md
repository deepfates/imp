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

**2026-07-25T19:10:40Z**

Broad consumer-semantics checkpoint through `8809fdf`. Runtime repairs after the prior checkpoint now include InferRules evaluation-error enforcement, recursive Ensemble demo rebinding, native categorical-TPE exploration, consumer-usable SFT/GRPO training validation, Avatar failed-candidate rejection, and a supported Optimize Anything best-candidate accessor. Documentation now names InferRules' whole-loop deviations and removes whole-port and unmeasured BEAM-superiority language. A clean-room package consumer constructs and executes LabeledFewShot, BootstrapFewShot, RandomSearch, KNNFewShot, COPRO, MIPROv2, SIMBA, GEPA, and InferRules through public paths; these deterministic Static-LM programs establish callable lifecycle and candidate application, not effectiveness.

Evidence remains separated by kind. Independently executed upstream behavior consists of the preserved 15-case GEPA v0.1.4 structural differential, narrow pinned DSPy 3.2.1 differentials for the few-shot/instruction families, exact InferRules formatting/update observations plus a controlled upstream loop probe, and freshly recaptured AvatarOptimizer/mmGRPO source-bound C1 observations. Imp unit and package-consumer behavior is broader than those upstream probes. Structural fixtures cover deterministic candidate/trace/lifecycle paths. No new family-wide held-out optimization result was established in this slice; the Optimize Anything schema-v2 multi-seed train/selection/test campaign and the killer reusable-program example remain open. InferRules is not whole-loop equivalent: Imp protects the baseline, isolates immutable candidates instead of sharing mutable signature classes, records/skips proposal and evaluation failures instead of aborting, resolves the rule LM explicitly, uses sequential BEAM rollout IDs, and does not retry oversized rule prompts by dropping examples.

The existing hierarchy remains authoritative: this ticket states the endpoint; `benchmarks/claims.json` states public claims; `benchmarks/authorities.json` pins upstream identities; `benchmarks/reproductions.json` maps surfaces, protocols, and admitted evidence; `mix benchmark.dashboard` computes status; generated conformance/maintainer pages are projections; older matrices and fidelity notes are context only. Fresh AvatarOptimizer and mmGRPO execution restored strict source-bound registry agreement without relaxing validation. The dashboard is again 10 proven / 25 blocked / 19 informational and profile-ready remains false.

Churn from `927cd8e^` through `8809fdf`, counting additions plus deletions, is 825 library/runtime lines (16.1%), 2,624 admission/benchmark lines (51.1%), and 1,683 test/doc/support lines (32.8%). Immutable admitted receipts account for 1,957 of the benchmark lines; excluding them, the split is 825 runtime (26.0%), 667 evidence infrastructure (21.0%), and 1,683 tests/docs/support (53.0%). This records the receipt-heavy diff without treating receipt volume as product progress. No head-to-head result currently supports a BEAM-native superiority claim.

Verification: the default suite passed 53 doctests, 9 properties, and 2,283 tests with zero failures and 11 skips; the exact AvatarOptimizer/mmGRPO evidence tests passed 7/7; the strict reproduction registry/check and dashboard reconciliation passed; `mix package.check` passed 13/13 plus fresh unpacked tutorial, persistence/tamper, and release probes. Highest remaining facades are held-out optimizer effectiveness across the advertised families, Optimize Anything's schema-v2 live campaign, provider-backed BootstrapFinetune/GRPO quality and continuation behavior, BetterTogether's sub-10-row validation/selection semantics and real weight step, and full InferRules loop comparison. The epic remains open.

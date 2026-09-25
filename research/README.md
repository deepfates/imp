# Research

This directory holds what stands behind Imp's published numbers and its claims
of matching DSPy: the results table, the notes on each comparison, and the
experiments that produced them. It is for checking those claims from a source
checkout. None of it ships in the Hex package or appears on hexdocs, and none
of it is needed to use Imp.

## Where to start

- [RESULTS.md](RESULTS.md) has every published number, one row each, with its
  dataset, license, model, provider, date, commit and the command that
  produces it. Nothing elsewhere restates a number without citing a row.
- [BENCHMARKS.md](BENCHMARKS.md) says what each of those commands needs (an
  API key, a Python environment, a local model, time, rough cost) and lists
  the claims that cannot be re-measured at all.
- [EVIDENCE.md](EVIDENCE.md) says which kind of check stands behind which kind
  of claim.
- [CASE_STUDY_TREC.md](CASE_STUDY_TREC.md) is the strongest matched result,
  GEPA and MIPROv2 on TREC, with the command that recomputes it.
- [differentials/](differentials/README.md) has one note per comparison with
  pinned DSPy and GEPA: what upstream does, what Imp does, and where they
  differ on purpose.

## The experiments

Each directory below is a runnable experiment with its own README, its
inputs, and the results it produced (the `exercised-*` files). Most need a
local model (Ollama or an MLX training job) or a provider key; the README says
which, and what the run costs.

| Directory | What it runs |
| --- | --- |
| `matched_instruction_optimizers_trec/` | GEPA and MIPROv2 in Imp and DSPy on the same TREC splits ([case study](CASE_STUDY_TREC.md)) |
| `tutorial_ticket_routing_experiment.exs` | The support-ticket router from Getting started, zero-shot and with `LabeledFewShot`, repeated live (row R1) |
| `matched_instruction_family_ifbench/` | Instruction optimizers compared on IFBench (design only; its DSPy side needs a module that is no longer in the repository, see its README) |
| `local_gepa_ifbench_cross_task/` | GEPA on IFBench with source-disjoint splits |
| `local_*_banking77/` | One optimizer each (COPRO, GEPA, GRPO, InferRules, KNNFewShot, MIPROv2, RandomSearch, SignatureOptimizer, SIMBA) on a local Banking77 classifier |
| `local_simba_trec/`, `local_simba_feedback_trec/` | SIMBA on a TREC router, with and without semantic feedback |
| `local_optimize_anything_retry_policy/` | Optimize Anything on a retry policy; `provider_free.exs` runs without a model |
| `optimizer_lifecycles/` | Demonstration and instruction optimizers from selection through saving, reloading and serving |

Run an experiment from the repository root with `mix run research/<dir>/run.exs`
(or `mix run research/tutorial_ticket_routing_experiment.exs`), or from its
directory when it has its own `mix.exs`. Its README gives the exact command.

Earlier matched GEPA and MIPROv2 runs on IFBench are not in this repository.
`RESULTS.md` lists what they found, by commit, among its findings that are
not results.

## Checking without spending

These run with no key and no model, and are part of `mix check`:

```sh
# Recompute the TREC case study from its committed rows.
mix run --no-start research/matched_instruction_optimizers_trec/recompute_compact.exs -- \
  research/matched_instruction_optimizers_trec/contract.json \
  research/matched_instruction_optimizers_trec/data/imp-scored-rows.json \
  research/matched_instruction_optimizers_trec/data/upstream-scored-rows.json \
  research/matched_instruction_optimizers_trec/data/aggregate-recomputed.json

# The tests over the retained results and the experiments' provider-free paths.
mix test test/case_study_trec_recomputation_test.exs test/optimizer_lifecycle_artifact_test.exs
```

The differentials against pinned DSPy need its Python environment
(`scripts/setup_dspy_parity_env.sh`, `scripts/setup_dspy_stable_source.sh`) and
then run with `mix differential.check`.

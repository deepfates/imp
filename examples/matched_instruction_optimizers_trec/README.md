# Matched local instruction optimizers on TREC

This is a bounded, provider-free integration diagnostic for Imp's instruction
optimizers. It runs baseline, GEPA, and MIPROv2 through native Imp and pinned
upstream implementations on the same real two-route TREC task. Its one seed and
small optimizer budgets are deliberately insufficient for parity or
effectiveness claims.

The frozen contract is [`contract.json`](contract.json). It binds stable DSPy
`3.2.1` at commit `29448ae12756abdd14bd8796c819247ebb83673c`, standalone
GEPA `0.1.4`, one diagnostic seed, exact 20-train/20-selection/40-held-out
source IDs, locally installed model digests, strict DSPy ChatAdapter marker
decoding, one transport attempt, local-only non-billable execution, and maximum
call ceilings. Both runtimes use matched ChatAdapter rendering with JSON
fallback disabled, retain exact rendered messages and raw response metadata,
and perform no output normalization.

The 20-row balanced selection split retains the original six validation IDs,
then takes the lexicographically earliest unused calibration IDs in each route
until both routes have ten rows. It never uses the current held-out split. Some
calibration rows have appeared in earlier, unrelated local work, so this is not
an independent effectiveness benchmark.

The runners open only `train.jsonl` and `selection.jsonl` while compiling and
selection-scoring all three arm programs. They fsync every selected artifact
and one selection receipt before either runner opens `held_out.jsonl`. GEPA
train examples receive the same frozen semantic feedback text in both runtimes;
selection examples return only scalar scores, and held-out rows remain outside
the optimizer. Upstream typed parse failures become scored row errors instead
of aborting the diagnostic.

Inspect the no-model plan from the repository root:

```sh
cd examples/matched_instruction_optimizers_trec
mix run -e 'Code.require_file("contract.exs"); IO.puts(Jason.encode!(MatchedInstructionOptimizersTREC.Contract.plan!("contract.json"), pretty: true))'
```

The plan starts no model or Python runtime and performs no download. It reserves
570 total local calls across both runtimes: 540 task calls and 30
proposal/reflection calls. Every runner owns a role-aware budget which refuses a
logical/transport call before dispatch; post-stage reconciliation separately
checks the retained ledger. `max_input_tokens` is passed to Ollama as `num_ctx`
and checked against returned usage.

MIPROv2's 14 optimizer-call ceiling follows DSPy 3.2.1's public grounded
proposer estimate (dataset summary, program-aware context, and two instruction
candidates). Imp normally needs fewer proposal transports because it composes
those contexts into each candidate request; both paths are bounded before
dispatch rather than forced to manufacture equal internal call counts.

The execution entry points are intentionally kept next to the example:

```sh
cd examples/matched_instruction_optimizers_trec
mix deps.get
mix run run_imp.exs

../../tmp/dspy-parity-venv/bin/python run_upstream.py \
  --dspy-root ../../tmp/dspy-3.2.1 \
  --gepa-root ../../tmp/gepa-v0.1.4
```

After both complete, one shared aggregator recomputes every score from row
identity/order and emits paired runtime/arm deltas:

```sh
mix run -e 'Code.require_file("contract.exs"); Code.require_file("aggregate.exs"); IO.puts(Jason.encode!(MatchedInstructionOptimizersTREC.Aggregator.aggregate!("contract.json", "../../tmp/matched_instruction_optimizers_trec/imp-result.json", "../../tmp/matched_instruction_optimizers_trec/upstream-result.json"), pretty: true))'
```

With one seed, the exact observed paired range is necessarily a point. It is not
a confidence interval and must not be described as uncertainty evidence. Both
runners fail closed on source, dataset, model, route, cost, attempt, parser, or
budget drift. Results are interpreted only as a bounded local diagnostic, not
flagship evidence, general optimizer parity, effectiveness, or BEAM
superiority.

Default results and sealed artifacts are written under the repository's
gitignored `tmp/matched_instruction_optimizers_trec/` directory. Both runners
record the full clean Imp `HEAD` plus the pinned DSPy and GEPA commits before
the first model catalog request; a dirty source tree is refused.

# Matched local instruction optimizers on TREC

This is the ordinary, provider-free flagship comparison for Imp's instruction
optimizers. It runs baseline, GEPA, and MIPROv2 through both native Imp and the
exact pinned upstream implementations on the same real two-route TREC task.

The frozen contract is [`contract.json`](contract.json).
It binds DSPy `3.3.0b1`, standalone GEPA `0.1.4`, three seeds, the exact
20-train/6-selection/40-held-out source IDs, locally installed model digests,
strict DSPy ChatAdapter marker decoding, one transport attempt, local-only
non-billable execution, and the maximum call envelope. Both runtimes use the
matched ChatAdapter rendering with JSON fallback disabled, retain exact rendered
messages and raw response metadata, and perform no output normalization.

The contract binds three example-local JSONL files to the pinned source rows.
The runners open only `train.jsonl` and `selection.jsonl` while compiling and
selection-scoring all nine seed/arm programs. They fsync every selected artifact
and one selection receipt before either runner opens `held_out.jsonl`. GEPA train
examples receive the same frozen semantic feedback text in both runtimes;
selection examples return only scalar scores, and held-out rows remain outside
the optimizer.

Inspect the no-model plan from the repository root:

```sh
cd examples/matched_instruction_optimizers_trec
mix run -e 'Code.require_file("contract.exs"); IO.puts(Jason.encode!(MatchedInstructionOptimizersTREC.Contract.plan!("contract.json"), pretty: true))'
```

The plan starts no model or Python runtime and performs no download. It reserves
1,986 total local calls across both runtimes and all three seeds: 1,932 task
calls and 54 proposal/reflection calls.

The execution entry points are intentionally kept next to the example rather
than embedded in the older AIME evidence runner:

```sh
cd examples/matched_instruction_optimizers_trec
mix deps.get
mix run run_imp.exs

../../tmp/dspy-parity-venv/bin/python run_upstream.py \
  --dspy-root ../../tmp/dspy-current-target \
  --gepa-root ../../tmp/gepa-v0.1.4
```

Both runners fail closed on source, dataset, model, route, cost, attempt, parser,
or budget drift. They write one immutable result per runtime and never use
held-out labels during optimization or selection. Results are interpreted as
task/model-specific matched evidence, not general optimizer parity,
effectiveness, or BEAM superiority.

Default results and sealed artifacts are written under the repository's
gitignored `tmp/matched_instruction_optimizers_trec/` directory. Both runners
record the full clean Imp `HEAD` plus the pinned DSPy and GEPA commits before
the first model catalog request; a dirty source tree is refused.

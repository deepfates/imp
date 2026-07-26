# Strong matched instruction optimizers on TREC

This directory defines the launch-blocked strong-model comparison for Imp and
pinned DSPy. It supersedes the small local diagnostic at commit `0a6cafe` for
release decisions; that diagnostic remains historical evidence, not a flagship.

The frozen contract binds DSPy 3.2.1 (`29448ae…`), GEPA 0.1.4 (`8b0ce6…`),
OpenAI GPT-5.4 Mini for task calls, Anthropic Claude Sonnet 4.6 for optimizer
calls, three seeds, and disjoint balanced splits of 20 train, 40 selection, and
80 untouched TREC rows. The opaque labels are K11 and K47. Dedicated selection
and untouched files are independently hashed, so neither optimizer runtime can
decode the full 400-row source or test labels during optimization.

The scientific headline is falsifiable: on the frozen comparison, at least one
Imp optimizer must improve its own baseline after Holm correction and remain
within -0.05 held-out accuracy of its pinned upstream counterpart. A clean
negative result falsifies that headline; it does not authorize changing seeds,
messages, models, splits, budgets, or parsing after results.

## Current boundary

The exact treatment is sealed after the integrated pinned GEPA execution,
MIPRO information-flow, dependency, route, and fail-closed preflights passed.
The safe predispatch ceilings are 6,840 task calls plus 102 optimizer calls across both runtimes. Their
conservative reservation is $38.43072. The aggregate workshop spend must be
confirmed immediately before launch against the owner's $50 ceiling.

The runners additionally fail closed on:

- exact first-party OpenRouter provider identity, eligible endpoint parameters,
  response service tier, and prices no higher than the sealed catalog prices;
- fallback disabled, `data_collection: deny`, one transport, cache/retry off,
  and task request seed equal to the experiment seed;
- a shared conservative request bound—compact UTF-8 bytes plus 16 bytes for
  every message and one assistant frame—below the input-token ceiling;
- per-arm call ceilings and cumulative worst-case USD reservation before each
  dispatch (unused reservation never creates extra calls);
- actual upstream provider versus OpenRouter gateway identity, service tier,
  token counts, and reconciled gateway-reported versus adapter-computed cost;
- MIPRO optimizer marker parsing before DSPy's data-aware fallback boundary;
  ordinary task-output parse failures remain matched score-zero rows;
- both runtimes durably sealing all nine selections before either can open the
  untouched file.

Baseline and a frozen injected-instruction no-model probe require byte-identical
task messages. Live candidate instructions may legitimately diverge; each must
instead be proven present in its runtime's rendered request. GEPA uses
`execution_profile: :gepa_v0_1_4`; MIPRO uses
`proposer_fidelity: :dspy_3_2_1` plus
`search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup`. The committed Python
dependency lock is checked byte-for-byte before catalog access. These modes
provide pinned semantic opportunity for this frozen one-predictor comparison,
not a blanket claim that independently evolving optimizer trajectories emit
identical messages.

Inspect the no-network plan from the repository root:

```sh
mix run -e 'Code.require_file("examples/matched_instruction_optimizers_trec/contract.exs"); IO.puts(Jason.encode!(MatchedInstructionOptimizersTREC.Contract.plan!("examples/matched_instruction_optimizers_trec/contract.json"), pretty: true))'
```

Materialize the exact upstream environment from the committed lock rather than
the repository's rolling parity setup script:

```sh
uv venv --python 3.13.2 tmp/dspy-parity-venv
uv pip sync --python tmp/dspy-parity-venv/bin/python \
  benchmarks/requirements-dspy-3.2.1-optuna-4.9.lock
```

The Imp and upstream runners must start
concurrently so their selection barrier can complete. The shared aggregator
recomputes all row metrics, performs source-ID-clustered paired bootstrap across
the three seeds, applies Holm correction to the two Imp improvement tests, and
checks noninferiority for the winning optimizer.

No provider calls have been made by this strong comparison. Until a complete
run exists, it supports no effectiveness, parity, generality, or BEAM-native
superiority claim.

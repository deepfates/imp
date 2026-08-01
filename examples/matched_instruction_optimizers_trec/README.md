# Strong matched instruction optimizers on TREC

This directory defines the sealed strong-model comparison for Imp and
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

## Completed outcome

The sealed treatment completed on 2026-07-27 under the owner's `$100` aggregate
workshop provider ceiling. Imp GEPA improved its mean untouched accuracy over
its own baseline by `+0.4000` (source-ID-clustered 95% interval
`[0.2958, 0.5042]`, Holm-adjusted `p = 0.00020`). Its mean difference from
pinned DSPy GEPA was `-0.0083`, with 95% interval `[-0.0458, 0.0292]`, clearing
the preregistered `-0.05` noninferiority margin. Imp MIPROv2 also improved its
own baseline by `+0.1458`, with interval `[0.0458, 0.2458]` and Holm-adjusted
`p = 0.00270`. The frozen headline therefore passed with GEPA as the declared
winner.

The committed compact result is
`benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json`.
It binds
the full retained Imp, upstream, and aggregate artifacts by SHA-256; those raw
artifacts remain local because they contain 181 MB of per-call evidence.
The treatment used 6,491 calls and `$3.13862325` in provider-reported cost.
Adding the conservative pre-treatment workshop bound yields at most
`$6.221975` against the `$100` ceiling.

The compact scored-row inputs are committed separately from the private raw
provider traces. From the repository root, a third party can rerun the frozen
gold-label checks, row scoring, clustered bootstrap, Holm correction, and
noninferiority decision with one provider-free command:

```sh
mix run --no-start \
  examples/matched_instruction_optimizers_trec/recompute_compact.exs -- \
  examples/matched_instruction_optimizers_trec/contract.json \
  benchmarks/evidence/archive/matched_experiments/trec/imp-scored-rows.json \
  benchmarks/evidence/archive/matched_experiments/trec/upstream-scored-rows.json \
  benchmarks/evidence/archive/matched_experiments/trec/aggregate-recomputed.json
```

This verifies the statistics asserted by the compact rows. It does not
independently revalidate private provider responses, request routing, cost,
selection sealing, or artifact provenance. Maintainers with the retained raw
files can regenerate the projection with `compact_evidence.exs`; that extractor
also verifies both raw runtime hashes and semantic equality with the retained
original aggregate before writing the public files.

A coordinated partial run had previously falsified the old
assumption that four nominal GEPA generations imply exactly four runtime
iterations. Pinned GEPA checks `max_metric_calls = 280` only between iterations
and legally finishes an iteration that began below the limit. For the frozen
40-row validation set and 10-row minibatch, the exact no-model envelope is 330
task metric calls, at most 24 started iterations, and at most 48 reflection
transports. The complete GEPA arm's separate operational caps are therefore 450
task and 48 optimizer transports after selection and untouched evaluation.

Across both runtimes and three seeds, the revised outer safety envelope is
7,140 task calls plus 342 optimizer calls. Its conservative reservation is
$59.10912. With the current conservative workshop aggregate of $3.08335175,
the combined worst case is $62.19247175 and fits the owner's `$100` ceiling.
The semantic stopping rule is unchanged; the outer cap is operational only,
and firing it makes the treatment inconclusive rather than scoring a truncated
arm.

The runners additionally fail closed on:

- exact first-party OpenRouter provider identity, eligible endpoint parameters,
  response service tier, and prices no higher than the sealed catalog prices;
- fallback disabled, `data_collection: deny`, one transport, cache/retry off,
  and task request seed equal to the experiment seed;
- provider-reported input and output token counts below the shared ceilings;
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

The only supported live entry starts the Imp consumer project and upstream
runtime as one fail-closed pair. From the repository root, load the key without
printing it and invoke the coordinator:

```sh
set -a
. ../.env
set +a
python3 examples/matched_instruction_optimizers_trec/run_paired.py
```

Before giving either child the provider key, the coordinator checks both
runtime locks and revisions, the exact Imp example cwd, manifest and route
shape, empty active result/barrier state, the cross-runtime guard-equivalence
gate, and the sealed cumulative spend bound. Either preflight failure starts
neither peer; either runtime failure interrupts the other. Interrupted peers get
a bounded SIGTERM rescue window to persist stopped artifacts and exact cost
state before process-group force termination. The shared aggregator
recomputes all row metrics, performs source-ID-clustered paired bootstrap across
the three seeds, applies Holm correction to the two Imp improvement tests, and
checks noninferiority for the winning optimizer.

Several stopped integration attempts made provider calls but never opened the
untouched barrier and support no optimizer outcome. The completed artifact
supports only this task/model-specific matched result. It does not establish
general GEPA or MIPROv2 effectiveness, paper-family replication, DSPy
superiority, BEAM-native superiority, or evidence for SIMBA, COPRO, InferRules,
or any other optimizer family.

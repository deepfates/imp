# Benchmarks

Every number this repository publishes is in one table,
[benchmarks/RESULTS.md](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md),
with the command that produces it. This page says what each of those commands
needs from you — key, Python environment, time, rough cost — and, at the end,
what we claim that you cannot check.

Nothing here is a release score. There is no aggregate, no grade, and no
dashboard. A benchmark tells you about the task, the model and the budget it
ran on; carrying it further is your judgment, not ours.

## The three kinds of check

**Differentials** compare Imp against a pinned upstream — DSPy 3.2.1 at commit
`29448ae12756abdd14bd8796c819247ebb83673c`, GEPA 0.1.4 — on deterministic
inputs. They need a Python environment, not an API key. They cost nothing, take
minutes, and have no sampling noise. When they disagree, one of the two
implementations is wrong, and the disagreement is exact enough to point at the
line. This is where fidelity evidence comes from.

**Provider-free runners** execute Imp's own machinery — optimizers, scorers,
retrievers, the failure campaign — against fixtures or a deterministic oracle.
They need neither a key nor Python. They prove that the machinery runs and that
its outputs are stable; they say nothing about whether a model got the answer
right.

**Live measurements** call a real provider and cost real money. There are two
of them in this repository that a stranger can run: the ticket-routing tutorial
(about a cent) and the agent-optimization deployment example (about seven
cents). Everything else that was measured live was measured once, by us, and is
recorded as a retained result rather than a command you can repeat cheaply.

## Live: what you can measure yourself

### Ticket routing (rows R1, R2)

```sh
OPENAI_API_KEY=… mix run scripts/tutorial_ticket_routing_experiment.exs
```

Also accepts `OPENROUTER_API_KEY` with `openai/gpt-5.4-mini`. Set
`TUTORIAL_REPEATS=1` for a single repeat.

- **Needs:** an OpenAI or OpenRouter key. No Python, no dataset download; the
  sixty tickets ship in the package at `priv/tutorial/support_tickets.json`.
- **Time:** 8–9 seconds per repeat, three repeats by default.
- **Cost:** about `$0.013` per repeat at `gpt-5.4-mini` prices; the script
  enforces a hard budget of `$1.00` per repeat and refuses to exceed it.
- **What it measures:** held-out accuracy of a four-way enum router before and
  after `LabeledFewShot(k: 8)`, on twenty tickets the optimizer never saw.
- **What it does not measure:** anything about your data, and anything about
  the search optimizers. Twenty rows move in 5-point steps.

This is the one end-to-end effectiveness number an outsider can reproduce from
scratch. [The tutorial](TUTORIAL_TICKET_ROUTING.md) walks through the same
experiment as ordinary library code.

### Agent optimization (row R6)

```sh
cd examples/deployment && OPENROUTER_API_KEY=… mix run agent_optimization.exs
```

- **Needs:** an OpenRouter key with access to `openai/gpt-5.4-mini` and
  `anthropic/claude-sonnet-4.6`.
- **Cost:** about `$0.065`, under two separate one-dollar hard caps.
- **What it measures:** whether Optimize Anything can improve three ReActV2
  tool descriptions, scored on the actual ordered tool calls, results,
  termination and final answer of four held-out requests — not on model prose.
- **What it does not measure:** agent effectiveness. Four requests is a
  4-point instrument, and the result moved one point.

`mix test test/deployment_agent_optimization_example_test.exs` checks the
retained result and Artifact without spending anything.

## Differentials: free, deterministic, need Python

All of these run under one command:

```sh
mix differential.check
```

which is `mix test --raise --only dspy_parity`. Before it will run you need the
pinned upstream sources and virtual environments:

```sh
scripts/setup_dspy_parity_env.sh
scripts/setup_dspy_stable_source.sh
git clone --filter=blob:none https://github.com/gepa-ai/gepa.git tmp/gepa-v0.1.4
git -C tmp/gepa-v0.1.4 checkout --detach v0.1.4
PYTHONPATH="$PWD/tmp/gepa-artifact" scripts/setup_corrected_gepa_comparator.sh tmp/gepa-artifact
python3 -m venv tmp/ifbench-parity-venv
tmp/ifbench-parity-venv/bin/python -m pip install -r benchmarks/requirements-ifbench-parity.txt
```

Python 3.12, a full (non-shallow) clone, and `zsh` on the path. About fifteen
minutes of setup, under a minute to run, no API key, no cost. The exact
sequence CI uses is the `differential` job in `.github/workflows/ci.yml`.

Individual differentials can be run on their own, and each has a note saying
what it compares and what it deliberately does not:

| Command | Compares | Note |
| --- | --- | --- |
| `mix parity.check` | Rendered messages and per-call request envelopes, byte for byte, against DSPy 3.2.1 | [Adapter fidelity](https://github.com/deepfates/imp/blob/main/docs/differentials/ADAPTER_FIDELITY.md) |
| `mix benchmark.instruction_optimizer.contract.check` | MIPROv2 and SIMBA control flow against pinned upstream | [Instruction optimizer fidelity](https://github.com/deepfates/imp/blob/main/docs/differentials/INSTRUCTION_OPTIMIZER_FIDELITY.md) |
| `mix benchmark.gepa.contract.check` | GEPA 0.1.4 reflective datasets, reflection prompts, module rotation, stopping decisions, on a recorded tape | [ComBee-style aggregation](https://github.com/deepfates/imp/blob/main/docs/differentials/COMBEE_FIDELITY.md) |
| `mix imp.benchmark.auto_evaluation_contract` | `SemanticF1` and `CompleteAndGrounded` scoring contracts | [Auto-evaluation differential](https://github.com/deepfates/imp/blob/main/docs/differentials/AUTO_EVALUATION_DIFFERENTIAL.md) |
| `mix imp.benchmark.avatar_actor_differential`, `mix imp.benchmark.avatar_optimizer_differential` | Avatar actor and trajectory optimizer | [Avatar fidelity](https://github.com/deepfates/imp/blob/main/docs/differentials/AVATAR_FIDELITY.md) |
| `mix imp.benchmark.mmgrpo_differential` | `Imp.Optimizer.GRPO` against DSPy's `GRPO.compile/3` | [mmGRPO differential](https://github.com/deepfates/imp/blob/main/docs/differentials/MMGRPO_C1.md) |
| `mix imp.benchmark.bootstrap_finetune_differential`, `mix imp.benchmark.better_together_differential` | BootstrapFinetune and BetterTogether | [Weight composition](https://github.com/deepfates/imp/blob/main/docs/differentials/WEIGHT_COMPOSITION_C1.md) |
| `mix benchmark.rlm.contract.check` | Recursive Language Model operational contracts | [RLM fidelity](https://github.com/deepfates/imp/blob/main/docs/differentials/RLM_FIDELITY.md) |
| `mix imp.benchmark.ax_contract` | Imp against Ax, an independent TypeScript implementation | [Ax differential](https://github.com/deepfates/imp/blob/main/docs/differentials/AX_DIFFERENTIAL.md) |
| `mix imp.benchmark.rag_tool_failure_differential` | A queued action schedule through Imp and DSPy ReAct, including a retriever-tool exception | — |
| `mix imp.benchmark.hotpot_retrieval` | Document ids, top-k contexts, supporting-fact recall and extractive EM/F1 over a shared 100-document corpus | — |
| `mix imp.benchmark.bootstrap_few_shot_differential`, `mix imp.benchmark.random_search_differential` | BootstrapFewShot and BootstrapFewShotWithRandomSearch against pinned upstream | — |
| `mix imp.benchmark.ensemble_differential` | Ensemble selection and reduction | — |
| `mix imp.benchmark.optimize_anything_upstream_differential` | Optimize Anything against the upstream reflective loop | — |
| `mix imp.benchmark.rlm_runtime_differential` | RLM runtime control flow | [RLM fidelity](https://github.com/deepfates/imp/blob/main/docs/differentials/RLM_FIDELITY.md) |

A differential proving that Imp matches DSPy on an input says nothing about
whether either one helps your program. Those are separate questions and this
page keeps them apart.

## Provider-free runners: free, no Python

| Command | What it exercises |
| --- | --- |
| `mix benchmark.optimizer_lift.check` | Deterministic optimizer lift on fixture tasks, including a natural classification lane |
| `mix benchmark.truth.check` | Colors, Iris, Iris-Typo, Heart Disease, hard math and local instruction-following rows end to end through fetch, run and integrity |
| `mix benchmark.failure_campaign.check` | Cancellation, bounded admission, terminal partial-stream failures, checkpoint and tamper recovery, flake rates, leak accounting |
| `mix benchmark.overhead.check` | Per-operation timing against per-case absolute and reference-relative budgets. These are measurements, not a speed claim |
| `mix benchmark.trace.check` | Golden prompt traces |
| `mix benchmark.copro_isolation.check` | COPRO candidate isolation |
| `mix benchmark.bfcl_scorer.check` | A BFCL-shaped scorer against an independent implementation. Not official BFCL performance |
| `mix imp.benchmark.confidence_calibration` | Constrained-label token confidence against empirical calibration |
| `mix imp.benchmark.playbook` | Playbook parameters through optimization and persistence |
| `mix benchmark.fast_slow.check` | The fast/slow learning handoff protocol |
| `mix imp.benchmark.multimodal_quality` | Multimodal encoding and decoding. Explicitly not live multimodal reasoning |
| `mix benchmark.operations_stress.check` | Save/load, cache hit/miss telemetry, redaction, malformed JSON/XML/chat, partial streams. A diagnostic, not a claim |
| `mix benchmark.search.check` | Search execution under bounded concurrency |
| `mix benchmark.rlm.check` | The RLM benchmark over a small fixture split |
| `mix benchmark.rag_tool_failure.check` | A retriever-tool exception through both runtimes. Not a wall-clock timeout comparison |
| `mix imp.benchmark.gepa_dataset` | Materializes what GEPA family data is present. See the absence noted below |

`mix benchmark.parity.check` and `mix benchmark.parity.full` download GSM8K and
HotPotQA and run both runtimes over them; `parity.full` is 7,405 HotPotQA rows
and is not cheap in time. `mix benchmark.live.check` runs two rows of each
against a live provider and needs a key. `mix imp.benchmark.local_mlx` needs a
local MLX model rather than a provider.

## Statistics you can recompute, but not reproduce

### Matched GEPA and MIPROv2 on TREC (rows R3, R4, R5)

```sh
mix run --no-start \
  examples/matched_instruction_optimizers_trec/recompute_compact.exs -- \
  examples/matched_instruction_optimizers_trec/contract.json \
  examples/matched_instruction_optimizers_trec/data/imp-scored-rows.json \
  examples/matched_instruction_optimizers_trec/data/upstream-scored-rows.json \
  examples/matched_instruction_optimizers_trec/data/aggregate-recomputed.json
```

Free, offline, about a minute including compilation. It re-derives the gold
label checks, row scoring, source-clustered bootstrap, Holm correction and the
noninferiority decision from committed scored rows, prints what it computed,
and exits non-zero if any of it disagrees with the committed aggregate.

What it cannot do is tell you that the committed rows are what the providers
returned. The raw request-level traces are 181 MB and were not published, so
the step between "a model answered" and "a row says it answered this" is taken
on trust. That is the whole distinction between recomputable and reproducible,
and [the case study](CASE_STUDY_TREC.md) states it in its first paragraph.

## Cannot be re-measured

Stated plainly, because the alternative is implying these are checkable.

**The GEPA six-family campaign.** `benchmarks/data/gepa-campaign-full/families.json`
pins AIMEBench, HotpotQABench, hoverBench, IFBench, LiveBenchMathBench and
Papillon with per-split SHA-256 digests and row counts. The split files are
absent — not three of six, none of them. Nothing in this repository can run that
campaign, and no result from it is claimed. See
[the attribution note](https://github.com/deepfates/imp/blob/main/benchmarks/data/GEPA_SPLITS_ATTRIBUTION.md).

**The matched IFBench 16k rehearsal.** It stopped in the held-out phase and
produced no verdict. Its earlier reported comparison was withdrawn in full
because the two figures were different quantities. The stopped run's records
are a dated observation in RESULTS.md, not a result.

**The historical negatives** — HotPotQA JSON-GEPA, Banking77 modeled-MIPRO, the
Grue stateful-agent run, the IFBench scorer defect. Each was a real run whose
retained artifacts diagnosed it. They are in RESULTS.md as findings with their
dates. Re-running them would cost money, would not reproduce the same numbers,
and in the IFBench case would run against a scorer that has since been fixed.

**The `ifbench_instruction_following` task is not IFBench.** Its rows are
written in `bench/imp/benchmark_truth/fetcher.ex`. A score on them is a score
on our verifier smoke rows. See
[the note](https://github.com/deepfates/imp/blob/main/benchmarks/data/IFBENCH_ATTRIBUTION.md).

**Anything about your task.** Imp does not claim an optimizer helps a program
until a held-out result on that program says so. Two tasks in this repository
have such a result; both are small; neither is yours.

## Dataset licenses

| Data | License |
| --- | --- |
| `priv/tutorial/support_tickets.json` | MIT — [written here](https://github.com/deepfates/imp/blob/main/priv/tutorial/SUPPORT_TICKETS_LICENSE.md) |
| `benchmarks/data/hotpotqa-validation-0-10.jsonl` | CC BY-SA 4.0 — [attribution](https://github.com/deepfates/imp/blob/main/benchmarks/data/HOTPOTQA_ATTRIBUTION.md) |
| `benchmarks/data/grpo-usefulness-banking77-v1.json`, `examples/deployment/data/banking77-*.json` | CC BY 4.0 |
| `examples/deployment/data/hotpotqa-gepa/` | CC BY-SA 4.0 |
| `benchmarks/data/rlm/` | declared in `provenance.json` |
| `benchmarks/data/confidence-calibration-trec-fine.jsonl` | **unknown** — [attribution](https://github.com/deepfates/imp/blob/main/benchmarks/data/TREC_ATTRIBUTION.md) |
| GEPA six-family splits | **unknown** for three of six families — [attribution](https://github.com/deepfates/imp/blob/main/benchmarks/data/GEPA_SPLITS_ATTRIBUTION.md) |
| IFBench corpus used by the matched examples | **unknown** — [attribution](https://github.com/deepfates/imp/blob/main/benchmarks/data/IFBENCH_ATTRIBUTION.md) |

Imp's MIT license covers our code and our derived split files. It does not
replace the license of any upstream corpus.

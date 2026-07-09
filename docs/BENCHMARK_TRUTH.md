# Benchmark Truth

DSEx has two benchmark lanes, one outside-view benchmark catalog, and one
release-level validation program.

DSEx keeps benchmark evidence behind Mix tasks instead of treating benchmark
helpers as part of the application API. Deterministic production fixtures prove
that core mechanics keep working: structured parsing, tools, program
optimization, and artifact optimization.

The benchmark truth tasks are the research-evidence lane. They run DSEx
programs over canonical DSPy-style dataset rows, write auditable result JSON,
and separate fixture-mode harness proof from live-provider evidence.

`BENCHMARK_CATALOG.md` maps the broader DSPy paper/docs/example benchmark
universe to DSEx's current samplers and gaps. `PARITY_VALIDATION_PROGRAM.md`
defines the full release evidence standard. A full-row live benchmark is one
important lane, but it is not sufficient by itself. Full parity claims also
require provider-free golden trace parity, optimizer lift parity,
RAG/tool/agent semantics, and provider-free performance benchmarks.

## Canonical Minimum

The first benchmark truth suite targets the datasets and task families most
closely tied to DSPy examples and papers:

- GSM8K: math word problems for chain-of-thought reasoning.
- HotPotQA: multi-hop question answering, with context/retrieval pressure.
- Color-style classification: retained as a simple low-cost smoke task in the
  dataset layer, not yet a benchmark truth gate.

DSPy's public docs list HotPotQA, GSM8K, and Color as built-in datasets. The
DSPy paper lineage evaluates math word problems and multi-hop QA, especially
GSM8K and HotPotQA. DSEx should not claim benchmark parity until it has run
real provider/model comparisons over fixed train/dev/test manifests.

The broader benchmark backlog is intentionally larger than this minimum. See
`docs/BENCHMARK_CATALOG.md` for classification/factuality, retrieval-indexed
QA, hard math, optimizer-lift, tool-use, and deferred long-form writing lanes.
Current source-checkout smoke evidence includes local IFBench-style rows with
executable constraint verifiers and local AIME/MATH-style rows with normalized
exact answer scoring.

## Fetch Data

```sh
mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 20 --out benchmarks/data
```

For a full canonical split fetch:

```sh
mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data
```

`--full` currently means GSM8K test `1319` rows and HotPotQA distractor
validation `7405` rows. Full fetches use HuggingFace's Parquet exports by
default so they can retrieve the canonical splits without hammering the rows
API. Small `--length` fetches use the rows API and record every source page URL
in the manifest. A single API page is not treated as a full dataset.

The fetcher uses HuggingFace's datasets-server rows API and writes:

- `*.jsonl` normalized rows
- `*.manifest.json` source URL, dataset/config/split, offset, row count,
  timestamp, input keys, and SHA256 digest

Generated data lives under `benchmarks/data/` and is ignored by git. Commit
small fixtures only when they are needed for deterministic tests.

## Check Data Integrity

```sh
mix dsex.benchmark.integrity \
  --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \
  --out benchmarks/results \
  --require-clean
```

This writes a `benchmark-data-integrity-*.json` artifact. The check fails on
missing required fields and HotPotQA rows whose declared supporting-fact pages
are absent from the flattened context. It also records non-blocking warnings
when an extractive answer string is not present in the context. Those warnings
are useful because they identify rows where an exact-match score may reward
parametric knowledge rather than retrieval-grounded reasoning.

## Run Fixture Proof

```sh
mix benchmark.truth.check
```

This runs the benchmark harness with checked-in GSM8K/HotPotQA-shaped fixtures
and an oracle LM. It proves:

- loaders accept benchmark-shaped records
- GSM8K canonical-answer extraction works
- HotPotQA context flattening works
- DSEx programs can be evaluated over the real benchmark artifact schema
- result JSON includes dataset digests, per-row scores, git SHA, Elixir, and OTP
- result JSON includes baseline-vs-optimized smoke comparisons for
  `LabeledFewShot`, `BootstrapFewShot`, `COPRO`, `MIPROv2`, `SIMBA`, and
  `GEPA` over the sampled rows when at least two examples are available

It does not prove model quality.

## Run Golden Trace Parity

```sh
mix benchmark.trace.check
```

This is the provider-free DSEx-vs-DSPy parity lane. It replays checked-in
fixture responses through DSEx and the Python DSPy sidecar, then writes a
`golden-trace-parity-*.json` artifact. The current corpus covers:

- `Predict` with field-labelled chat output
- `ChainOfThought`
- typed output coercion
- JSON adapter output
- ReAct lookup tool trajectory normalized across DSPy trajectory fields and
  DSEx provider tool calls
- multi-tool ReAct trajectory normalization
- ReAct tool-argument error status parity
- missing-field error status parity
- normalized prediction parity
- retained DSEx and DSPy message histories for prompt-template review
- DSEx semantic checks for incremental field streaming, save/load credential
  redaction, ReqLLM cache hits, and provider text/tool-call stream chunk replay

This lane is intentionally stricter and cheaper than live benchmark parity:
prediction and expected-error parity must pass without provider nondeterminism.
It does not claim byte-identical prompt/message-template parity; DSEx keeps an
Elixir-native provider-tool prompt shape and records both message histories so
template differences stay reviewable instead of hidden.

## Run Provider-Free Overhead Parity

```sh
mix benchmark.overhead.check
```

This lane compares DSEx and Python DSPy without provider latency. It runs local
runtime benchmarks for:

- signature parsing
- adapter message formatting
- adapter response parsing
- schema validation
- evaluation loop throughput
- metric normalization
- optimizer trial scheduling
- trace redaction and JSON serialization
- cache hits and misses
- concurrent orchestration

The artifact reports per-case median, mean, p95, min, max, and
`median_ratio_dsex_over_dspy`. The production gate currently enforces a
conservative maximum ratio of `50.0` so regressions are visible without
pretending every local path is faster. Speed claims must name the exact case and
artifact they come from; slower paths such as cache miss overhead are evidence
for focused optimization work, not for marketing claims.

## Run Optimizer Lift Parity

```sh
mix benchmark.optimizer_lift.check
```

This provider-free lane uses a deterministic task with known baseline and
optimum scores. The current artifact directly compares DSEx and DSPy
`LabeledFewShot`, `BootstrapFewShot`, `RandomSearch`, `COPRO`, `MIPROv2`, and
`SIMBA` and `GEPA` lift when the installed DSPy sidecar exposes them. It records
documented DSEx-only or intentional-deviation evidence for Elixir-native
`InstructionSearch` and provider-side trainer workflows such as finetuning and
GRPO. The artifact records the installed Python `dspy` package version and
detected optimizer capabilities so the lane stays honest as the upstream runtime
changes. The same artifact includes natural DSEx user-story lanes for
classification, QA, retrieval/KNN few-shot, and instruction following, with
baseline score, optimized score, lift, call counts, cost estimate, and selected
demos or instructions.

## Run GEPA Paper Replication

```sh
mix benchmark.gepa_replication.check
```

This source-checkout lane runs a deterministic smoke campaign by default and
validates GEPA paper-family artifact shape. It does not turn provider-free
optimizer lift or smoke rows into a paper claim. A full artifact must cover
`AIMEBench`, `HotpotQABench`, `hoverBench`, `IFBench`,
`LiveBenchMathBench`, and `Papillon`; for each row it must report baseline,
DSPy GEPA, DSEx GEPA, MIPROv2, metric-call budget, token/cost, wall-clock,
seed variance, and train/dev/test gap. Full rows must also carry a campaign id,
dataset source and split checksums, source commits for DSPy, DSEx, and the GEPA
artifact, concrete non-placeholder comparator sources, distinct train/dev/test
split digests, and positive live token/cost accounting. SIMBA can appear as an
extra comparator when a campaign includes it, but it is not part of the upstream
GEPA artifact's required optimizer list.

When upstream GEPA artifact experiments have been run, convert their
`experiment_runs_data` output into DSEx dashboard rows with:

```sh
mix dsex.benchmark.gepa_dataset \
  --gepa-root path/to/gepa-artifact \
  --out benchmarks/data/gepa-campaign

mix dsex.benchmark.gepa_campaign \
  --dataset-root benchmarks/data/gepa-campaign \
  --campaign-id gepa-full-YYYYMMDD \
  --model openai:gpt-4.1-mini-2025-04-14 \
  --reflection-model openai:gpt-5 \
  --pricing-source "provider usage export 2026-07-09" \
  --input-tokens 123456 \
  --output-tokens 23456 \
  --usd 1.23 \
  --dspy-source stanfordnlp/dspy@<sha> \
  --gepa-artifact-source gepa-ai/gepa-artifact@<sha> \
  --out benchmarks/results

mix dsex.benchmark.gepa_replication \
  --from-gepa-artifact path/to/gepa-artifact/experiment_runs_data \
  --dsex-input benchmarks/results/dsex-gepa-rows-*.json \
  --campaign-id gepa-full-YYYYMMDD \
  --artifact-model gpt-41-mini
```

The DSEx campaign producer expects a `families.json` file plus one directory
per GEPA family, each with `train.jsonl`, `dev.jsonl`, and `test.jsonl`.
`families.json` declares each family’s signature, instructions, input keys,
output key, program name, metric-call budget, upstream metric name, source
commit, split counts, and split checksums. The dataset exporter imports the
upstream GEPA artifact benchmark classes and preserves their split construction.
The converter then reads upstream `Baseline`, `GEPA`, and `MIPROv2-Heavy`
`evaluation_result.txt` files and merges them with DSEx-produced `dsex_gepa`
rows. It refuses missing families, missing comparator outputs, ambiguous
artifact models, and rows that do not satisfy the full-evidence contract after
merge.

The exported `families.json` records upstream metric names. DSEx currently
ports deterministic metric adapters for AIME integer exact match, HotPotQA
answer exact match, HoVer supporting-title retrieval, IFBench
instruction-registry constraints, Papillon LLM-judge quality/leakage scoring,
the deterministic LiveBenchMath AMC/AIME parser paths, and LiveBenchMath
`imo`/`usamo` proof-rearrangement edit-distance scoring. Papillon campaigns must
pass a judge LM and emitted research rows must include `metric_judge` metadata
naming the judge model plus quality/leakage judge semantics; the full GEPA
replication contract rejects Papillon rows without that provenance. Unknown
LiveBenchMath task branches now fail closed. LiveBenchMath `amps_hard` remains
guarded because upstream uses SymPy/Lark symbolic equivalence; install and
validate the symbolic Python bridge before claiming AMPS_Hard parity.

## Run RAG, Tool, And Agent Parity

```sh
mix benchmark.rag_tool_agent.check
```

This provider-free lane directly compares DSEx and DSPy on deterministic RAG
retrieval/answering and ReAct lookup-tool semantics. It also records DSEx
production-semantics evidence for HTTP retriever protocol shape, MCP import
through agents, tool policy denial traces, ReAct error traces, CodeAct,
ProgramOfThought success and sandbox rejection, streaming incremental fields,
BEAM async execution, and save/load redaction. Provider behavior over real
models remains covered by the live matched-model lane.

## Run RLM Benchmark Parity

```sh
mix benchmark.rlm.check
```

This provider-free lane compares DSEx RLM and Python DSPy RLM over
HotPotQA-shaped long-context fixture rows. The artifact includes direct prompt,
simple RAG, and RLM approaches with score, latency, subcall count, trace shape,
and statistical uncertainty. It proves operational parity for the RLM execution
surface; live model-quality RLM claims require a separate sampled live campaign.

## Run Live Benchmark Smoke

```sh
OPENAI_API_KEY=... OPENAI_MODEL=... mix benchmark.live.check
```

This fetches two fresh rows from GSM8K and HotPotQA, runs DSEx programs against
a live provider, and writes a result artifact under `benchmarks/results/`.

## Run DSEx vs DSPy Parity

Install Python DSPy in the local parity environment:

```sh
scripts/setup_dspy_parity_env.sh
```

The setup script chooses `python3.13`, `python3.12`, `python3.11`, or
`python3.10`, then installs current stable DSPy with the `optuna` extra needed
by MIPROv2:

```sh
# Equivalent manual setup:
python3.12 -m venv tmp/dspy-parity-venv
. tmp/dspy-parity-venv/bin/activate
python -m pip install -U pip setuptools wheel "dspy[optuna]>=3.2.1,<3.3" openai
```

Then run:

```sh
OPENAI_API_KEY=... mix benchmark.parity.check
```

This runs DSEx and the real Python `dspy` package over the same fetched GSM8K
and HotPotQA rows, using the same OpenAI-compatible model. For reproducible
evidence, set `OPENAI_MODEL` or pass `--model` with a provider model id you have
verified in the current account. If neither is set, DSEx queries the
OpenAI-compatible `/models` endpoint and auto-selects only when exactly one
text-generation-looking candidate is visible. If discovery fails, returns no
candidate, or returns multiple candidates, the task stops and asks for an
explicit `--model`; it does not invent a fallback model or choose among paid
models on the operator's behalf.

The parity report records:

- DSEx and DSPy versions/runtime metadata
- benchmark prompt/signature contract identity for each runtime
- requested and effective generation settings, including endpoint route
  evidence
- task scores and aggregate score delta
- task latency and DSEx/DSPy latency ratio
- error counts
- row-level pass/fail agreement and answers
- bounded disagreement examples and per-task disagreement direction counts
- evidence scale: `smoke`, `research_sample`, or `full`

This is the required lane for parity claims. DSEx-only benchmark truth proves
DSEx behavior; parity requires the Python DSPy sidecar.

Two rows are a smoke test, not a leaderboard. They prove only that both sides
can run against the same data and endpoint. Use research samples or the full
lane before making quality/efficiency claims:

```sh
mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 200 --out benchmarks/data
mix dsex.benchmark.parity \
  --gsm8k benchmarks/data/gsm8k-test-0-200.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-200.jsonl \
  --max-examples 200 \
  --models "$CURRENT_LOW_COST_MODEL,$FRONTIER_SANITY_MODEL"
```

OpenAI is the default parity provider. For another provider, make both sides
explicit so the artifact proves a matched operational path instead of an
accidental OpenAI-shaped comparison:

```sh
PROVIDER_API_KEY=... mix dsex.benchmark.parity \
  --gsm8k benchmarks/data/gsm8k-test-0-200.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-200.jsonl \
  --max-examples 200 \
  --model "$DSEX_PROVIDER_MODEL" \
  --dspy-model "$DSEX_DSPY_MODEL" \
  --api-key-env PROVIDER_API_KEY
```

The DSEx side takes a ReqLLM model spec such as `anthropic:...` or
`google:...`; the DSPy side takes the matching LiteLLM/DSPy model name such as
`anthropic/...` or `gemini/...`. The artifact records both wire API families so
the live matrix can reject endpoint mismatches.

The intentionally expensive full live row lane is:

```sh
OPENAI_API_KEY=... mix benchmark.parity.full
```

That command fetches GSM8K test and HotPotQA distractor validation in full, then
runs DSEx and Python DSPy over the same rows. It can take a long time and spend
real provider money. Its artifacts can support the live matched-model part of a
full parity claim, but not the entire claim by themselves. Use
`PARITY_VALIDATION_PROGRAM.md` for the complete standard.

## Aggregate Live Model Matrix

```sh
mix benchmark.live_matrix
```

This consumes existing `dsex-dspy-parity-campaign-*.json` artifacts and writes
`live-matched-model-matrix-*.json`. It is the canonical answer to "which
provider/model lanes have actually been proven?" It groups by provider and
model, skips malformed historical artifacts, tags current low-cost, frontier,
and historical/research-style lanes, and reports whether each lane satisfies
its release-evidence policy.

Lane tags are model-family evidence buckets, not vendor commitments. Current
low-cost includes small/mini/nano/Haiku/Flash/Lite-style models; frontier sanity
includes current flagship-style GPT, Claude Sonnet/Opus, and Gemini Pro models;
historical/research-style includes legacy GPT-3.5/Davinci, Claude 3-era, Gemini
1.x, or explicitly research/legacy-labeled models.

The matrix is intentionally an evidence index, not a benchmark runner.
`current_low_cost` requires one full accepted canonical campaign. Frontier and
historical/research lanes require fresh matched research samples: enough rows
to expose provider drift without pretending every flagship or legacy model must
pay the full canonical cost. If the matrix reports smoke coverage, stale prompt
contracts, incomplete current low-cost coverage, or unsatisfied research-sample
lanes, DSEx has not yet proven live matched model parity. Each model row and
live-lane blocker reports covered rows,
remaining rows, percent coverage, and estimated remaining/full DSEx-plus-DSPy
tokens so staged campaigns can be planned from the dashboard instead of hand
calculated. Cost is token-only by default; set
`DSEX_BENCH_INPUT_USD_PER_1M` and `DSEX_BENCH_OUTPUT_USD_PER_1M` when you want
the matrix to include USD estimates from current provider pricing.

When a lane has multiple candidate models, the lane-level `coverage` and `cost`
headline the strongest candidate because one satisfying model is sufficient for
that lane. The same objects retain a nested `cumulative` summary so operator
dashboards can still see total evidence and spend across all candidates.

The selected artifact for a model must also carry the current DSEx benchmark
prompt contract compiled into the benchmark truth runner. Older artifacts
remain valuable history, but they are not release evidence after the task prompt
or signature contract changes. The matrix exposes this as
`summary.prompt_contract.complete`, and the dashboard reports
`prompt_contract_incomplete` until every selected live model lane is current.

When a dataset contract changes or a fresh full campaign supersedes older
smoke evidence, filter the matrix to the intended lineage:

```sh
DSEX_BENCH_CAMPAIGN_ID=req-llm-current-low-cost-full-YYYYMMDD \
  mix benchmark.live_matrix
```

The lower-level task also accepts `--campaign-id`. This prevents invalidated
artifacts from winning matrix selection merely because they contain more rows
from an older benchmark contract.

For operationally safer full runs, execute fixed-size chunks with `--offset`
and `--max-examples`, then preserve every emitted artifact:

```sh
mix dsex.benchmark.parity \
  --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \
  --campaign-id req-llm-current-low-cost-full-YYYYMMDD \
  --env-file .env \
  --offset 0 \
  --max-examples 100 \
  --max-concurrency 8 \
  --model "$CURRENT_LOW_COST_MODEL"
```

Chunked runs avoid losing an entire benchmark to one network interruption. A
full parity claim still requires covering the complete row range. Use one
stable `--campaign-id` for all chunks in a fresh run; aggregation can then
exclude older smoke artifacts instead of mixing them into the full-campaign
claim.

To advance a campaign without babysitting each offset:

```sh
mix dsex.benchmark.parity.campaign \
  --model "$CURRENT_LOW_COST_MODEL" \
  --dspy-model "$CURRENT_LOW_COST_DSPY_MODEL" \
  --campaign-id req-llm-current-low-cost-full-YYYYMMDD \
  --env-file .env \
  --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \
  --chunk-size 100 \
  --chunks 5 \
  --target-coverage 1000 \
  --max-concurrency 8 \
  --reasoning-effort low
```

For non-OpenAI campaign lanes, use the provider-qualified ReqLLM model as
`--model`, the matching DSPy/LiteLLM model as `--dspy-model`, and the relevant
`--api-key-env`. The campaign driver forwards those settings to every chunk.
For example, Anthropic uses `--model anthropic:claude-haiku-4-5` on the DSEx
side and `--dspy-model anthropic/claude-haiku-4-5` on the Python DSPy side.
Do not pass the ReqLLM colon form as `--dspy-model`; omit the flag when the
default DSEx mapper can derive the matching LiteLLM id.

For measured transport A/B checks, configure ReqLLM's Finch pool before startup
through the same runner:

```sh
mix dsex.benchmark.parity.campaign \
  --model "$DSEX_PROVIDER_MODEL" \
  --dspy-model "$DSEX_DSPY_MODEL" \
  --api-key-env PROVIDER_API_KEY \
  --env-file .env \
  --req-llm-pool-protocols http1 \
  --req-llm-pool-count 16 \
  --chunk-size 100 \
  --chunks 1
```

Use this for measured transport experiments, not as a hidden release-policy
escape hatch. Release evidence should record the campaign id, model, generation
settings, and pool settings whenever they change.

When resuming a release campaign after concurrency experiments, keep passing the
release `--max-concurrency` value. The campaign runner forwards that value to
aggregation, so coverage and next offsets are computed from the comparable
execution slice instead of mixing older serial/concurrent chunks into one
latency claim.

`--chunks` limits how many new chunks this invocation may run.
`--target-coverage` limits the total campaign coverage to reach before
stopping. When both are present, the runner aggregates current evidence before
each chunk, chooses the next canonical missing offset, shrinks `--max-examples`
for the chunk when the target is near, and stops as soon as the aggregate has
reached the requested paired-row coverage. This is the preferred way to run
staged live campaigns because the stopping condition is evidence coverage, not a
hand-counted number of offsets.

If a live chunk produces runner/API errors, the campaign runner halts after that
chunk instead of continuing to spend provider calls. Any rows with complete
DSEx/DSPy evidence are preserved, but quota/rate-limit failures remain
incomplete evidence, not negative benchmark rows. Fix provider
quota/credentials or switch to a matched provider/model lane, then rerun the
same campaign id to continue from the earliest missing accepted row.

Use `--dspy-model responses/<model>` when the matching Python DSPy/LiteLLM path
must force OpenAI Responses endpoint semantics for the selected model. DSEx
reaches the provider through ReqLLM; the explicit DSPy model route prevents
comparing Responses semantics against Chat Completions semantics by accident.

For reasoning models, add `--reasoning-effort low` when the parity question is
throughput and answer-quality parity under a bounded reasoning budget. The
campaign artifact records requested and effective reasoning effort, and
aggregation treats different reasoning-effort settings as different generation
contracts so latency evidence cannot be mixed accidentally.

If `--campaign-id` is omitted, the campaign task creates a unique id for that
invocation. Reuse an explicit id when resuming a long full campaign later.

`mix benchmark.live_matrix` also reads `benchmarks/model_availability.json` by
default. Use that file for documented external model unavailability, not for
convenience skips. For example, historical GPT-3.5 snapshots that are no longer
stable API baselines can satisfy the `historical_research` lane only when the
file names the unavailable lane, explains the limitation, and links to provider
deprecation evidence. Current-model full coverage remains required for the
`current_low_cost` lane.

Concurrency improves wall-clock time by issuing independent row calls in
parallel on both the DSEx and Python DSPy sides. It does not reduce the number
of benchmark rows or provider calls, and reports record `max_concurrency` so
serial and concurrent artifacts are auditable. Campaign aggregates require one
consistent `max_concurrency` value before `full_parity` can be true; the live
matrix and dashboard surface mixed or missing concurrency evidence as a release
blocker because latency and throughput claims are not comparable otherwise.

Aggregate chunk artifacts into a campaign report:

```sh
mix dsex.benchmark.parity.aggregate \
  --provider req_llm \
  --model "$CURRENT_LOW_COST_MODEL" \
  --in "benchmarks/results/dsex-dspy-parity-${CURRENT_LOW_COST_MODEL}-*.json" \
  --max-concurrency 8
```

The aggregator counts each `(task, absolute_index)` once, so overlapping smoke
or retry chunks cannot inflate coverage. It also scopes reports by DSEx provider
and model, so historical direct-client artifacts cannot be mixed into ReqLLM
campaigns. Runner/API error rows are incomplete evidence: they are not included
in coverage or scores, and a newer incomplete row cannot replace an older
complete row for the same canonical index. This matters for quota/rate-limit
failures, where an attempted chunk may produce row shells without valid model
answers. Those rows stay rerunnable and appear as `runner_error_rows` and
missing ranges instead of being treated as both-failed parity rows. It reports:

- total covered rows versus canonical expected rows
- per-task covered rows, missing ranges, incomplete rows, and runner-error rows
- weighted DSEx/DSPy scores from row-level pass/fail outcomes
- aggregate and task score gaps
- latency ratio from covered chunk artifacts
- runtime instrumentation summaries: DSEx LM call counts, LM-duration share,
  local overhead, fallback/retry counts, prompt size, raw output size, and
  DSPy-side input/message/raw-size diagnostics. DSPy `message_chars` records
  its source as `lm_history` when a concurrent history entry is unambiguously
  attributable to the row, or `row_estimate` when the runner falls back to the
  canonical question/context shape so concurrency does not hide prompt-size
  evidence.
- explicit `full_parity: true/false`

`full_parity` is false unless every canonical row is covered, the prompt
contract and effective generation settings are consistent, complete, and
matched, `max_concurrency` is consistent across the campaign evidence, aggregate
and per-task score gaps are within the configured strict thresholds, and the
DSEx/DSPy latency ratio is within the configured `--max-latency-ratio` threshold
(`1.5` by default). Latency is part of the decision because parity is about
operational behavior, not only answer quality.

Historical checked-in campaign artifacts may be useful diagnostics, but they are
not release proof unless the live matrix selects them under the current prompt
contract, model-lane policy, effective generation settings, and concurrency
requirements. Treat stale named-model campaigns as prior evidence, not as a
template for new operator commands.

Use the `dsex_instrumentation`, `dspy_instrumentation`, and `runtime_shape`
summaries before optimizing runtime code. When DSEx `lm_duration_share` is close
to `1.0`, the observed live latency is dominated by the provider/model call
rather than DSEx adapter parsing or metric evaluation. Large DSEx-vs-DSPy
`message_chars` or `raw_chars` ratios point toward prompt/output shape work;
nonzero `json_fallbacks` or `parse_retries` point toward adapter recovery work.
`runtime_shape.coverage.complete` must be true before treating shape ratios as a
full-campaign comparison; otherwise they are partial diagnostics from the rows
where both runtimes exposed comparable instrumentation. The live matrix ranks
complete instrumentation/runtime-shape evidence ahead of larger nominal coverage
when selecting the representative artifact for a model lane, because inflated
coverage from quota-tainted or otherwise incomplete chunks is not release proof.
Review `dspy_instrumentation.message_chars_sources` before using shape ratios
for fine-grained prompt work: `lm_history` is exact sidecar evidence, while
`row_estimate` is deterministic diagnostic evidence for rows whose DSPy history
was ambiguous under concurrency.

## Evidence Standard

A credible DSEx benchmark report must include:

- dataset manifest SHA256 digests
- train/dev/test or offset/length split description
- model/provider/version metadata
- prompt/signature contract identity
- requested and effective generation settings
- DSEx git SHA
- baseline score
- optimized score
- optimizer settings
- per-example scores or enough row detail to audit failures
- a clear statement of whether the run used fixture, local, or live provider
  mode
- a clear statement of whether the evidence scale is smoke, research sample, or
  full

The current benchmark truth runner establishes the data/result substrate, live
smoke path, and optimizer comparison shape across the implemented prompt
optimizers. Full benchmark parity requires the broader validation program:
golden trace replay, live matched-model lanes, optimizer lift comparisons,
production-semantics tests, and provider-free performance reports. Tiny smoke
samples are useful release evidence, not leaderboard claims.

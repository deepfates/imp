# Benchmark Truth

DSEx has two benchmark lanes.

`DSEx.Benchmarks` contains deterministic fixtures for production gates. Those
tests prove that core mechanics keep working: structured parsing, tools,
program optimization, and artifact optimization.

`DSEx.BenchmarkTruth` is the research-evidence lane. It runs DSEx programs over
canonical DSPy-style dataset rows, writes auditable result JSON, and separates
fixture-mode harness proof from live-provider evidence.

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

## Fetch Data

```sh
mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 20 --out benchmarks/data
```

For a full canonical split fetch:

```sh
mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data
```

`--full` currently means GSM8K test `1319` rows and HotPotQA fullwiki
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

## Run Live Benchmark Smoke

```sh
OPENAI_API_KEY=... OPENAI_MODEL=gpt-4o-mini mix benchmark.live.check
```

This fetches two fresh rows from GSM8K and HotPotQA, runs DSEx programs against
a live provider, and writes a result artifact under `benchmarks/results/`.

## Run DSEx vs DSPy Parity

Install Python DSPy in the local parity environment:

```sh
python3 -m venv tmp/dspy-parity-venv
. tmp/dspy-parity-venv/bin/activate
python -m pip install -U pip setuptools wheel dspy-ai openai
```

Then run:

```sh
OPENAI_API_KEY=... mix benchmark.parity.check
```

This runs DSEx and the real Python `dspy` package over the same fetched GSM8K
and HotPotQA rows, using the same OpenAI-compatible model. If `OPENAI_MODEL` is
not set, DSEx queries the OpenAI-compatible `/models` endpoint and selects the
first available current model from `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`,
`gpt-5`, and `gpt-4.1`.

The parity report records:

- DSEx and DSPy versions/runtime metadata
- task scores and aggregate score delta
- task latency and DSEx/DSPy latency ratio
- error counts
- row-level pass/fail agreement and answers
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
  --models gpt-5.5,gpt-5.4-mini
```

The intentionally expensive full lane is:

```sh
OPENAI_API_KEY=... mix benchmark.parity.full
```

That command fetches GSM8K test and HotPotQA fullwiki validation in full, then
runs DSEx and Python DSPy over the same rows. It can take a long time and spend
real provider money. It is the lane whose artifacts can support a full parity
claim.

For operationally safer full runs, execute fixed-size chunks with `--offset`
and `--max-examples`, then preserve every emitted artifact:

```sh
mix dsex.benchmark.parity \
  --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \
  --offset 0 \
  --max-examples 100 \
  --model gpt-5.4-mini
```

Chunked runs avoid losing an entire benchmark to one network interruption. A
full parity claim still requires covering the complete row range.

Aggregate chunk artifacts into a campaign report:

```sh
mix dsex.benchmark.parity.aggregate \
  --model gpt-5.4-mini \
  --in 'benchmarks/results/dsex-dspy-parity-gpt-5.4-mini-*.json'
```

The aggregator counts each `(task, absolute_index)` once, so overlapping smoke
or retry chunks cannot inflate coverage. It reports:

- total covered rows versus canonical expected rows
- per-task covered rows and missing ranges
- weighted DSEx/DSPy scores from row-level pass/fail outcomes
- aggregate and task score gaps
- latency ratio from covered chunk artifacts
- explicit `full_parity: true/false`

`full_parity` is false unless every canonical row is covered and both aggregate
and per-task score gaps are within the configured strict thresholds.

## Evidence Standard

A credible DSEx benchmark report must include:

- dataset manifest SHA256 digests
- train/dev/test or offset/length split description
- model/provider/version metadata
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
optimizers. Full benchmark parity requires larger fixed manifests, repeated
runs, and model/provider comparison reports; tiny smoke samples are useful
release evidence, not leaderboard claims.

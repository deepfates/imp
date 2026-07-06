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

Two rows are a smoke test, not a leaderboard. Increase `--length` and
`--max-examples` for research runs:

```sh
mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 200 --out benchmarks/data
mix dsex.benchmark.run \
  --gsm8k benchmarks/data/gsm8k-test-0-200.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-200.jsonl \
  --max-examples 200 \
  --live \
  --model gpt-4o-mini
```

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

The current benchmark truth runner establishes the data/result substrate, live
smoke path, and optimizer comparison shape across the implemented prompt
optimizers. Full benchmark parity requires larger fixed manifests, repeated
runs, and model/provider comparison reports; tiny smoke samples are useful
release evidence, not leaderboard claims.

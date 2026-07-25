# Benchmark Truth

Imp has two benchmark lanes, one outside-view benchmark catalog, and one
release-level validation program.

Imp keeps benchmark evidence behind Mix tasks instead of treating benchmark
helpers as part of the application API. Deterministic production fixtures prove
that core mechanics keep working: structured parsing, tools, program
optimization, and artifact optimization.

The benchmark truth tasks are the research-evidence lane. They run Imp
programs over canonical DSPy-style dataset rows, write auditable result JSON,
and separate fixture-mode harness proof from live-provider evidence.

`BENCHMARK_CATALOG.md` maps the broader DSPy paper/docs/example benchmark
universe to Imp's current samplers and gaps. `PARITY_VALIDATION_PROGRAM.md`
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
GSM8K and HotPotQA. Imp should not claim benchmark parity until it has run
real provider/model comparisons over fixed train/dev/test manifests.

The broader benchmark backlog is intentionally larger than this minimum. See
`docs/internal/BENCHMARK_CATALOG.md` for classification/factuality, retrieval-indexed
QA, hard math, optimizer-lift, tool-use, and deferred long-form writing lanes.
Current source-checkout smoke evidence includes local IFBench-style rows with
executable constraint verifiers and local AIME/MATH-style rows with normalized
exact answer scoring.

## Fetch Data

```sh
mix imp.benchmark.fetch --tasks gsm8k,hotpotqa --length 20 --out benchmarks/data
```

For a full canonical split fetch:

```sh
mix imp.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data
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
mix imp.benchmark.integrity \
  --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl \
  --out benchmarks/runs/integrity \
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
- Imp programs can be evaluated over the real benchmark artifact schema
- result JSON includes dataset digests, per-row scores, git SHA, Elixir, and OTP
- result JSON includes baseline-vs-optimized smoke comparisons for
  `LabeledFewShot`, `BootstrapFewShot`, `COPRO`, `MIPROv2`, `SIMBA`, and
  `GEPA` over the sampled rows when at least two examples are available

It does not prove model quality.

## Run Golden Trace Parity

```sh
mix benchmark.trace.check
```

This is the provider-free Imp-vs-DSPy parity lane. It replays checked-in
fixture responses through Imp and the Python DSPy sidecar, then writes a
`golden-trace-parity-*.json` artifact. The current corpus covers:

- `Predict` with field-labelled chat output
- `ChainOfThought`
- typed output coercion
- JSON adapter output
- ReAct lookup tool trajectory normalized across DSPy trajectory fields and
  Imp provider tool calls
- multi-tool ReAct trajectory normalization
- ReAct tool-argument error status parity
- missing-field error status parity
- normalized prediction parity
- retained Imp and DSPy message histories for prompt-template review
- Imp semantic checks for incremental field streaming, save/load credential
  redaction, ReqLLM cache hits, and provider text/tool-call stream chunk replay

This lane is intentionally stricter and cheaper than live benchmark parity:
prediction and expected-error parity must pass without provider nondeterminism.
It does not claim byte-identical prompt/message-template parity; Imp keeps an
Elixir-native provider-tool prompt shape and records both message histories so
template differences stay reviewable instead of hidden.

## Run Provider-Free Overhead Parity

```sh
mix benchmark.overhead.check
```

The canonical alias requires a clean checkout. During development,
`mix imp.benchmark.overhead --no-require-clean ...` may produce a diagnostic
artifact, but the dashboard keeps its claim red and marks the candidate
ineligible until the integrated source is committed and rerun cleanly.

This lane compares Imp and Python DSPy without provider latency. It runs local
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

The artifact reports per-case median, mean, p95, min, max, and a measured
`median_ratio_imp_over_dspy`. Every operation has its own absolute Imp-median
budget, reference-relative median budget, operation contract, and rationale.
The cache hit, cache miss, schema-validation, and BootstrapFewShot cases execute
the same logical operation and matched configuration in both runtimes. The
artifact records BEAM, Python, OS, architecture, dependency, and clean-source
identity in a verified run envelope.

These budgets are regression alarms, not parity, superiority, or speed claims.
Ratios are measurements only. No path-specific speed claim is authorized by a
passing ceiling; such a claim would require a separately declared and powered
comparison.

## Run Shared Inference-Time Search Evidence

```sh
mix benchmark.search.check
```

This provider-free source-checkout lane runs the same natural answer-candidate
fixture through sequential and bounded-concurrent `Imp.Predict.Search`. Its
deterministic checks cover selected answer and quality, candidate-order
provenance, admitted projected budget, executed outcomes' projected budget,
and the observed concurrency bound. The artifact labels projected cost units
separately from actual provider cost; no provider is called, so billed usage is
unavailable rather than inferred.

The artifact also records latency sample distributions and the observed median
ratio. Those fields are measurements for the checkout, runtime, scheduler, and
configured synthetic work only. A concurrent speedup is not required and does
not participate in artifact pass/fail status. This lane therefore complements
the focused runtime tests without making a flaky wall-time release assertion or
a live model-quality, provider-latency, or provider-cost claim.

## Run Optimizer Lift Parity

```sh
mix benchmark.optimizer_lift.check
mix benchmark.instruction_optimizer.contract.check
mix benchmark.gepa.contract.check
```

This provider-free lane uses a deterministic task with known baseline and
optimum scores. The current artifact directly compares Imp and DSPy
`LabeledFewShot`, `BootstrapFewShot`, `RandomSearch`, `COPRO`, `MIPROv2`, and
`SIMBA` and `GEPA` lift when the installed DSPy sidecar exposes them. It records
documented Imp-only or intentional-deviation evidence for Elixir-native
`InstructionSearch` and provider-side trainer workflows such as finetuning and
mmGRPO. Imp's GRPO implementation authority is pinned DSPy 3.2.1 source;
DeepSeekMath is background rather than an implementation-parity authority. The
artifact records the installed Python `dspy` package version and
detected optimizer capabilities so the lane stays honest as the upstream runtime
changes. The same artifact includes natural Imp user-story lanes for
classification, QA, retrieval/KNN few-shot, and instruction following, with
baseline score, optimized score, lift, call counts, cost estimate, and selected
demos or instructions.

The second command runs the separate T1 structural differential against pinned
DSPy `3.3.0b1`. It validates exact source hashes and compares MIPROv2 budgets,
demo topology, proposal rotation, search-space shape, and full-evaluation cadence
plus SIMBA bucket, finalist, rollout, tied-rule, and eviction invariants.

The COPRO row in the lift artifact also carries a separate pinned, provider-free
process differential against the stable authority, DSPy `3.2.1` at commit
`29448ae12756abdd14bd8796c819247ebb83673c`. Prepare an absent environment with:

```sh
scripts/setup_dspy_stable_source.sh
IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh
```

Then capture the clean, source-bound C1 receipt with:

```sh
mix imp.benchmark.copro_isolation --require-clean --out tmp/copro-isolation
```

BootstrapFewShot and RandomSearch have separate provider-free, clean-source C1
protocols against the same stable DSPy authority:

```sh
mix imp.benchmark.bootstrap_few_shot_differential --require-clean --out tmp/bootstrap-few-shot-differential
mix imp.benchmark.random_search_differential --require-clean --out tmp/random-search-differential
```

The canonical BootstrapFewShot (`9b89dac9…`), RandomSearch (`f7e49685…`), and
COPRO (`5cf88e79…`) receipts were captured from a clean Imp commit reachable
from `origin/main` (`fd48e27`) after the honesty-pass merge changed the
authority-ledger bytes the previous receipts bound (an earlier generation had
also bound a never-pushed local commit, `0e96d62`, invisible to fresh clones). Their validators
recompute the exact source bindings and retained scopes. The protocols exclude
exact Python RNG, provider behavior/effectiveness, and full optimizer parity;
BootstrapFewShot also excludes repeated-call sampling parity, and RandomSearch
excludes shuffled-row-order parity.

The canonical validator is receipt-only and provider-free by default; fresh Python
replay is an explicit additional operation. The fixture starts COPRO in a fresh worker process after installing mutable parent
LM state. It verifies the canonical authority ledger, clean release commit/tag,
all 296 source-manifest files, distribution version, COPRO source, and upstream
test before binding fixture/script hashes. Proposal fan-out and order come from
the isolated DSPy LM's actual call history and parsed response choices, independent
of the expected-order assertion. The artifact records the tagged source's known
`dspy.__version__ == "3.2.0"` metadata anomaly separately from the authoritative
3.2.1 distribution/git identity. It also directly observes evaluation order and
equal-score duplicate removal. First-record retention is separately source-supported
by the pinned COPRO implementation's greater-than-or-equal score guard rather than
claimed as an independently observable artifact result. The fixture also covers
pinned `results_latest`/`results_best` statistics. This is narrow C1 behavioral
evidence only: it does not claim exact Python RNG parity, provider behavior,
effectiveness, or full optimizer parity.

Run the resumable, paid one-seed AIME preflight from the shared Imp/DSPy
manifest with:

```sh
mix imp.benchmark.instruction_optimizer_experiment \
  --manifest benchmarks/config/instruction-optimizer-aime-economical-preflight-haiku45-v1.json \
  --runtime both \
  --python tmp/dspy-parity-venv/bin/python \
  --dspy-pythonpath tmp/dspy-current-target \
  --out benchmarks/runs/instruction-optimizer-experiment
```

This command pins DSPy and Optuna, verifies immutable split hashes, maps the
same logical model to each runtime's provider identifier, and enforces the same
per-arm request/input/output/USD ceilings before merging results. It reports
frozen-test deltas for every arm. It does not choose a global winner from dev,
and its one seed is explicitly research preflight rather than T3 evidence.
The admitted Haiku 4.5 run completed baseline, MIPROv2, and SIMBA in both
runtimes without failures. All six runtime/arm rows scored `2/3` on frozen
test, which supports T2 live sampled behavior but neither optimizer lift nor
full parity.

The third command runs a T1 structural differential against standalone GEPA
`v0.1.4` at commit `8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`.
Set `IMP_GEPA_V014_ROOT` to the exact checkout and, when needed,
`IMP_GEPA_V014_PYTHON` to its Python environment. The task validates the tag,
commit, tagged project-version anomaly, and source hashes before comparing
provider-free acceptance, parallel proposal selection, Pareto, component
rotation, merge, frontier, budget, JSON resume/RNG, and named-program mutation
semantics. It explicitly does not establish paper reproduction, effectiveness,
or full optimizer parity. The older v0.1.1 artifact remains immutable history,
not the selected current contract.

Optimizer lift is outcome evidence, not full optimizer parity. The dashboard
keeps `full_optimizer_parity` false when the structural artifact is missing,
stale, authority-mismatched, or failing. Even a passing T1 artifact does not
replace held-out multi-seed T3 effectiveness evidence. Imp-only rows and equal
scores under unmatched internal decision paths cannot satisfy that stronger
claim.

## Run Optimize Anything Replication

Run the deterministic campaign contract and evaluator smoke with:

```sh
mix benchmark.optimize_anything.check
```

Run the live non-prompt effectiveness campaign with a pinned provider model:

```sh
mix imp.benchmark.optimize_anything \
  --live \
  --env-file .env \
  --provider openai \
  --model gpt-5.4-2026-03-05 \
  --pricing-profile openai-gpt-5.4-standard-2026-03-05 \
  --seeds 17,23,31 \
  --max-proposals 5 \
  --max-cost-usd 0.50 \
  --max-requests 20 \
  --max-input-tokens 100000 \
  --max-output-tokens 20000 \
  --max-output-tokens-per-request 1000 \
  --out benchmarks/runs/optimize-anything
```

The full lane optimizes three executable artifact classes: an Elixir retry
controller, a support-routing agent configuration, and a scheduling heuristic.
Each family has deterministic train and independently recomputed held-out
evaluators, a baseline, and an authored reference comparator. The comparator
is a positive control for evaluator headroom; it is not an upstream
Optimize Anything parity result.

Full evidence requires at least three distinct seeds, positive mean held-out
lift, a strict majority of improving seeds for every family, positive live
provider token and cost accounting, and per-run checkpoints. All seed
outcomes remain in the artifact, including ties and regressions. `--smoke`
proves campaign wiring and artifact validation only and never authorizes the
effectiveness claim. The dashboard consumes full artifacts through its
`optimize_anything` lane.

Live execution has no implicit spend allowance. It requires positive finite
ceilings for requests, input tokens, output tokens, per-request output tokens,
and dollars. Before each request, the campaign atomically reserves a
conservative input estimate plus the full per-request output allowance at the
declared prices; a reservation that could cross any ceiling rejects the call
before provider code runs. The evidence lane disables ReqLLM response caching
and transport retries, so one reservation owns one provider attempt. Provider
telemetry settles observed usage exactly once in the campaign ledger. Missing,
zero, non-finite, or non-one-to-one cost telemetry fails closed. If unexpected
provider accounting nevertheless reports usage above a declared bound on the
final call, that completed call remains in the checkpoint but the campaign
emits no full evidence.

Each ledger transition sync-writes a temporary file and renames it over the
latest checkpoint. The final checksummed envelope is embedded in the run
artifact; admission recomputes its digest and exact equality with the seed-row
aggregate without reading the local path. The path is informational and may be
nonportable. This is neither an append-only transition log nor a restart,
power-loss, or directory-fsync guarantee. Existing run ids are refused, and a
terminated run must be reviewed before starting a new run id with a newly
declared ceiling. The telemetry handlers accept only events emitted by the
campaign owner process, preventing unrelated concurrent ReqLLM calls from
contaminating cost evidence.

The pinned standard profile uses the official OpenAI API prices of $2.50 per
million input tokens and $15.00 per million output tokens from
<https://developers.openai.com/api/docs/pricing>. The documented $0.50 ceiling
is deliberately above the roughly $0.217 observed by the prior nine-run
campaign while remaining the configured pre-dispatch bound under the declared
prices, not a spending target. An unexpected provider accounting overrun is
retained in the checkpoint and invalidates evidence as described above. The
separately tracked $15 maximum belongs to the broader matched-upstream research
portfolio; it is not a spend allowance for this narrow three-class rerun and
does not add an asserted product claim. The
optional `openai-gpt-5.4-mini-standard-2026-03-17` profile uses $0.75/$4.50;
it is a cost-appropriate engineering option but has no retained effectiveness
claim until the unchanged three-class, three-seed policy passes. Other models
must supply explicit positive `--input-price-per-million`,
`--output-price-per-million`, and `--pricing-source-url` values instead of a
profile. Pricing-source URLs must be ordinary credential-free HTTP(S)
documentation URLs. Userinfo, credential or secret markers in recursively
decoded hosts, paths, queries, or fragments, excessive encoding, and
secret-shaped values are rejected rather than redacted because the URL is part
of source identity. Known profiles bind the exact provider, model, rates, and
authority URL at the CLI, campaign, and pure admission layers.

This campaign establishes Imp-native non-prompt optimization effectiveness at
the declared scale. It does not establish full paper reproduction or equality
with an upstream implementation under matched internals.

## Run GEPA Paper Replication

```sh
mix benchmark.gepa_replication.check
```

This source-checkout lane runs a deterministic smoke campaign by default and
validates GEPA paper-family artifact shape. It does not turn provider-free
optimizer lift or smoke rows into a paper claim. A full artifact must cover
`AIMEBench`, `HotpotQABench`, `hoverBench`, `IFBench`,
`LiveBenchMathBench`, and `Papillon`; for each row it must report baseline,
DSPy GEPA, Imp GEPA, MIPROv2, configured metric-call budget, observed metric
calls with enforced limits, token/cost, wall-clock, seed variance, seed-selection
provenance, and train/dev/test gap. Full rows must also carry a campaign id,
dataset source, dataset scope, split counts, split checksums, source commits
for DSPy, Imp, and the GEPA artifact, concrete non-placeholder comparator
sources, distinct train/dev/test split digests, and positive live token/cost
accounting. The full-evidence contract requires `dataset.scope == "full"` and
rejects capped `--max-per-split` dataset roots; capped roots are useful for
engineering proof runs only. SIMBA can appear as an extra comparator when a
campaign includes it, but it is not part of the upstream GEPA artifact's
required optimizer list.

The scalar `metric_calls` and `optimizer_budgets` fields describe configuration;
they are not proof that the optimizer observed or enforced those limits. Every
full row must additionally include `metric_call_evidence` with basis
`observed_and_enforced`, a concrete counter/export source, observed counts for
all four required optimizer rows, and an affirmed enforced limit for each count.
Copying configured budgets into an "actual" field, omitting runtime provenance,
using a configured-only basis, or reporting an observed count above its limit
keeps the dashboard GEPA lane red. Smoke evidence remains valid only at its
explicit lower tier.

Full rows must also include per-optimizer `seed_selection`. Accepted selection
methods are a predeclared seed, dev-only best-seed selection, or an aggregate
over declared seeds, all with concrete provenance and `test_scores_used: false`.
Choosing the reported best seed from test scores is test-set leakage and cannot
support parity or source-fidelity claims, even when seed variance is reported.
The Imp campaign passes every `--seeds` value and each family’s declared
`metric_calls` limit into `Imp.Optimizer.GEPA`, selects the reported seed by
dev score, and exports the optimizer report’s observed metric calls plus the
enforced limit for each seed. Comparator-side evidence must be added by the
upstream artifact converter before strict full-artifact validation.

### Source-Shaped Program and Feedback Contract

A full campaign conversion accepts exactly these six upstream family/program
shapes. The two `CoT` rows share a program name but retain their own source
signature, instructions, metric, splits, and budget; they are not
interchangeable rows.

| Family | Program | Source signature | Scored output |
| --- | --- | --- | --- |
| `AIMEBench` | `CoT` | `problem -> answer` | integer exact match |
| `HotpotQABench` | `HotpotMultiHop` | `question -> answer` | answer exact match |
| `hoverBench` | `HoverMultiHop` | `claim -> retrieved_docs` | supporting-title retrieval |
| `IFBench` | `IFBenchCoT2StageProgram` | `prompt -> response` | instruction constraints |
| `LiveBenchMathBench` | `CoT` | `question -> answer` | task-specific math score |
| `Papillon` | `PAPILLON` | `user_query -> llm_request, llm_response, response` | quality/leakage judge |

`HotpotMultiHop`, `HoverMultiHop`, and `IFBenchCoT2StageProgram` install
strict, named component-feedback maps. HotPot covers `summarize1`,
`create_query_hop2`, `summarize2`, and `final_answer`; HoVer covers
`summarize1`, `create_query_hop2`, `summarize2`, and `create_query_hop3`; and
IFBench covers `generate_response_module` and `ensure_correct_response_module`.
The map must cover the program graph exactly. Each callback receives the named
predictor input/output, full example, program output, metric result, and trace,
and must yield non-empty feedback text. Invalid callback output, a callback
failure, or a graph mismatch stops the optimization run. `AIMEBench`,
`LiveBenchMathBench`, and `Papillon` currently use metric-level feedback rather
than a custom component map. Campaign rows record the component-feedback
identity so reviewers can distinguish these contracts.

When upstream GEPA artifact experiments have been run, convert their
`experiment_runs_data` output into Imp dashboard rows with:

```sh
mix imp.benchmark.gepa_dataset \
  --gepa-root path/to/gepa-artifact \
  --out benchmarks/data/gepa-campaign

IMP_HOVER_UPSTREAM_BM25=1 \
IMP_IFBENCH_UPSTREAM_DESCRIPTIONS=1 \
IMP_GEPA_PYTHON=path/to/pinned/python \
IMP_GEPA_ROOT=path/to/gepa-artifact \
mix imp.benchmark.gepa_campaign \
  --manifest benchmarks/config/gepa-paper-campaign-v2.json

mix imp.benchmark.gepa_replication \
  --from-gepa-artifact path/to/gepa-artifact/experiment_runs_data \
  --upstream-evidence benchmarks/runs/gepa-replication/gepa-upstream-evidence.json \
  --imp-input benchmarks/runs/gepa-campaign/imp-gepa-rows-*.json \
  --campaign-id gepa-full-YYYYMMDD \
  --artifact-model gpt-41-mini
```

The canonical manifest independently binds the task, reflection, and Papillon
judge model roles, even when they share the same dated model identifier. This
matches the pinned paper artifact: GEPA leaves `teacher_lm` unset, so reflection
uses the configured task LM, while Papillon separately fixes its judge to
GPT-4.1-mini. The manifest also binds the six families, full dataset hash,
seeds, metric-call budgets, source commits, request policy, output paths, and
required source-exact environment. It also binds a checkpointed semantic
sentinel: five consecutive proposal errors abort without producing a result
artifact, while valid non-improving candidates remain ordinary GEPA evidence.
It rejects every CLI override. Direct CLI
mode remains available for partial operator runs, but it is not the canonical
paper-reproduction contract.

For long full-scope runs, execute one or more families at a time with
`--families AIMEBench,HotpotQABench`. These partial campaign artifacts are
resumable operator evidence; before conversion, merge the six family rows into
one Imp input artifact so the replication contract can verify the complete
paper-family set.

The Imp campaign producer expects a `families.json` file plus one directory
per GEPA family, each with `train.jsonl`, `dev.jsonl`, and `test.jsonl`.
`families.json` declares each family’s signature, instructions, input keys,
output key, program name, metric-call budget, upstream metric name, source
commit, dataset scope, optional max-per-split cap, split counts, and split
checksums. The dataset exporter imports the upstream GEPA artifact benchmark
classes and preserves their split construction. Passing `--max-per-split`
marks the root as `capped`, and those rows cannot satisfy a full GEPA research
claim. The converter then reads upstream `Baseline`, `GEPA`, and `MIPROv2-Heavy`
`evaluation_result.txt` files and merges them with Imp-produced `imp_gepa`
rows. It refuses missing families, missing comparator outputs, ambiguous
artifact models, and rows that do not satisfy the full-evidence contract after
merge.

The upstream evidence sidecar is mandatory for conversion. Generate it from
the immutable upstream experiment archive and the matching upstream checkout:

```sh
python3 scripts/extract_gepa_upstream_evidence.py \
  path/to/experiment_runs_data.tar.gz \
  --upstream-repo path/to/gepa-artifact \
  --model gpt-41-mini \
  --out benchmarks/runs/gepa-replication/gepa-upstream-evidence.json
```

The extractor requires the six family/program pairs above and the `Baseline`,
`GEPA`, and `MIPROv2-Heavy` seed-0 runs. It records the archive SHA-256 and
upstream commit; reads upstream `config.json`, metric JSONL, and
`evaluation_result.txt`; derives observed optimizer callbacks by subtracting
the matching Baseline final-test callbacks; and reads the configured comparator
budget from the upstream source. The replication task accepts only a sidecar
whose exact family/program/optimizer keys match the required comparator set,
whose reported test score and result SHA-256 match the archive result, and
whose evidence proves observed, enforced, within-budget calls and non-test seed
selection. It will not infer this evidence from `evaluation_result.txt` or
configured budgets alone.

Campaign or converted rows that still expose only configured call budgets or
select their reported seed by test score are useful operator artifacts, but they
do not satisfy the full GEPA contract. They must remain red until the producer
emits the observed/enforced call evidence and non-test seed-selection provenance
described above.

The exported `families.json` records upstream metric names. Imp currently
ports deterministic metric adapters for AIME integer exact match, HotPotQA
answer exact match, HoVer supporting-title retrieval, IFBench
IFEval-style instruction constraints, Papillon LLM-judge quality/leakage
scoring, the deterministic LiveBenchMath AMC/AIME parser paths, and
LiveBenchMath `imo`/`usamo` proof-rearrangement edit-distance scoring. GEPA
HoVer uses the upstream `HoverMultiHop` output contract (`claim ->
retrieved_docs`); the metric scores retrieved document titles against
`supporting_facts`, not the entailment label. Both `HotpotQABench` and
`hoverBench` require `dataset.retrieval` provenance for the same upstream
`wiki.abstracts.2017` BM25 corpus and index, including corpus and index
checksums. For either family, the campaign command requires
`IMP_HOVER_UPSTREAM_BM25=1`; it then executes retrieval through the pinned
upstream Python BM25S index. The native Elixir BM25 retriever is an explicitly
labeled approximation, not a source-exact campaign substitute: it does not
reproduce the upstream English stopword tokenizer or PyStemmer stemming. The
pinned Python adapter uses upstream commit
`cbefbc1aa0f43dd39874ec4bf42211365dbda42e`, `bm25s==0.2.12`, and
`pystemmer==2.2.0.3`; its fixed top-k title order is validated with
`IMP_HOVER_UPSTREAM_PARITY=1 mix test test/hover_bm25_parity_test.exs`. For
campaign rows over the full upstream corpus, set `IMP_HOVER_UPSTREAM_BM25=1`,
`IMP_GEPA_ROOT`, and `IMP_GEPA_PYTHON` for both families. Their multi-hop
queries are generated by the LM and the resulting rows report ReqLLM usage
telemetry. These rows do not support a full GEPA research claim until uncapped
results are merged with matching upstream comparator outputs and sidecar
evidence.
IFBench imports the larger AllenAI `instructions_registry`; Imp ports the
registry in Elixir and keeps unknown ids fail-closed rather than silently
scoring as false. Four upstream IFBench checks depend on Python NLP packages
(`nltk` stopwords/POS data, `emoji`, and `syllapy`). Imp ships native fallback
checks for normal deterministic evidence and a source-exact bridge for research
campaigns: set `IMP_IFBENCH_NLP_BRIDGE=scripts/ifbench_nlp_check.py` and, when
needed, `IMP_IFBENCH_NLP_PYTHON` to a Python with those packages and corpora.
The registry differential covers all 83 active merged-registry instruction ids
and matches the pinned GEPA artifact fixtures, including language detection and
the four NLP-backed checks. Reproduce it with:

Full IFBench GEPA campaigns also set
`IMP_IFBENCH_UPSTREAM_DESCRIPTIONS=1`, `IMP_GEPA_ROOT`, and
`IMP_GEPA_PYTHON`. Scoring remains in the Elixir registry port; reflective
feedback renders the corresponding human instruction descriptions through
`scripts/ifbench_upstream_describe.py` from the pinned upstream registry. The
campaign records that description source and fails closed if the bridge is
missing or returns an invalid description set.

```sh
python3 -m venv tmp/ifbench-parity-venv
tmp/ifbench-parity-venv/bin/python -m pip install \
  -r benchmarks/requirements-ifbench-parity.txt
tmp/ifbench-parity-venv/bin/python -m nltk.downloader \
  -d tmp/ifbench-parity-venv/nltk_data \
  stopwords averaged_perceptron_tagger_eng punkt_tab
NLTK_DATA="$PWD/tmp/ifbench-parity-venv/nltk_data" \
IMP_IFBENCH_UPSTREAM_PARITY=1 \
IMP_IFBENCH_UPSTREAM_PYTHON="$PWD/tmp/ifbench-parity-venv/bin/python" \
  mix test test/gepa_metrics_test.exs
```

The absolute interpreter path is intentional because the test runner may
change its working directory while spawning the upstream evaluator.
Papillon campaigns must pass a judge LM and emitted research rows must include
`metric_judge` metadata naming the judge model plus quality/leakage judge
semantics; the full GEPA replication contract rejects Papillon rows without
that provenance. Unknown LiveBenchMath task branches now fail closed.
LiveBenchMath `amps_hard` remains guarded because upstream uses SymPy/Lark
symbolic equivalence; install and validate the symbolic Python bridge before
claiming AMPS_Hard parity. The default bridge is
`scripts/livebench_math_score.py`; pin `IMP_LIVEBENCH_MATH_PYTHON` and, when
needed, `IMP_LIVEBENCH_MATH_BRIDGE` for research campaigns.

## Run RAG, Tool, And Agent Parity

```sh
mix benchmark.rag_tool_agent.check
```

This provider-free lane directly compares Imp and DSPy on deterministic RAG
retrieval/answering and ReAct lookup-tool semantics. It also records Imp
production-semantics evidence for HTTP retriever protocol shape, MCP import
through agents, tool policy denial traces, ReAct error traces, CodeAct,
ProgramOfThought success and sandbox rejection, streaming incremental fields,
BEAM async execution, and save/load redaction. Provider behavior over real
models can be measured directly in the same artifact:

The provider-free artifact is a bounded C2 operational-contract proof. It
requires exactly the two declared DSPy comparison rows, rejects missing or
duplicate rows, exercises the actual `Imp.rag` wrapper, and includes a
ReActV2 trajectory that recovers from failing, unknown, and malformed tool
calls before bounded submission. A source-bound candidate must be run from a
clean checkout and binds the Imp revision, pinned DSPy 3.2.1 authority, task
and sidecar hashes, and the provider-free fixture:

```sh
mix imp.benchmark.rag_tool_agent \
  --require-clean \
  --out benchmarks/runs/rag-tool-agent
```

The operational artifact does not measure HotPotQA answer/supporting-fact
quality or BFCL tool name/argument accuracy. The separate matched failure
differential below closes the missing provider-free schedule contract, but it
does not close comparative effectiveness because its actions are queued rather
than model-selected.

The separate provider-free HotPotQA retrieval differential uses the pinned
first ten `fullwiki` validation rows and materializes one shared corpus of 100
uniquely titled passages. It binds the dataset, split manifest, scorer/config,
Imp task, Python sidecar, and DSPy 3.2.1 authority by SHA-256. Both runtimes use
the same stable token-overlap ranking, document IDs, top five, and context
ordering, then report supporting-title recall plus extractive answer-availability
EM/F1:

```sh
mix imp.benchmark.hotpot_retrieval \
  --require-clean \
  --out benchmarks/runs/hotpot-retrieval
```

The bounded current result matches 10/10 rows and both aggregate summaries:
0.35 supporting-fact recall and 0.30 answer-availability EM/F1. The answer
scorer emits the gold answer only when it is present in retrieved context, so
this is retrieval/answer-availability evidence rather than language-model
generation quality. It does not close the broader HotPotQA effectiveness or
BFCL portfolio; the separate failure differential below is operational rather
than effectiveness evidence.

The BFCL-shaped provider-free lane is intentionally C1/T1 fixture-scorer
conformance, not an official BFCL sample, DSPy differential, or operational
benchmark. Its twelve positive rows and nine adversarial mutations are
original CC0 Imp-authored cases. The mutation corpus covers wrong, missing,
extra, and reordered calls; scalar types; array order; malformed JSON; invalid
terminals; and wrong valid terminals. The provenance block explicitly records
that no upstream BFCL prompts, answers, schemas, or dataset rows were copied.
Elixir and an independent Python stdlib implementation normalize JSON
string/map arguments, recursively canonicalize object keys while preserving
arrays and scalar types, and score exact tool names, call order, arguments,
terminal states, and fail-closed invalid input:

```sh
mix imp.benchmark.bfcl_adapted \
  --require-clean \
  --out benchmarks/runs/bfcl-adapted
```

The artifact must match 12/12 positives and 9/9 preregistered mutations with
1.0 scorer and mutation-detection agreement. It binds BFCL repository revision
`6ea57973c7a6097fd7c5915698c54c17c5b1b6c8` as protocol provenance only and
enumerates every adaptation from the official scorer. Neither official BFCL
nor DSPy scorer code executes. This establishes scorer-fixture agreement only;
it does not measure a model choosing calls and must not be reported as
operational evidence, DSPy parity, official BFCL accuracy, or tool-use
effectiveness.

Canonical admission is pure: it verifies the run envelope and pinned source
bindings, reconstructs the expected fixture scores, and requires both stored
implementations to equal those scores without executing Python. Maintainers may
request an explicit Python replay during a local audit, but replay is never part
of registry admission.

The provider-free RAG/tool failure differential preregisters six scenarios and
executes the identical queued action sequence through actual
`Imp.Predict.ReAct` in DSPy-3.2.1 mode and actual pinned DSPy 3.2.1 `ReAct`:

```sh
mix imp.benchmark.rag_tool_failure_differential \
  --require-clean \
  --python tmp/dspy-parity-venv/bin/python \
  --out benchmarks/runs/rag-tool-failure-differential
```

It compares every normalized action observation and terminal state exactly.
The schedule covers a transient failure followed by retry, a retriever-tool
timeout exception, duplicate idempotency-key replay, a tool removed from the
runtime registry, a permanent tool failure, `finish`/`submit` normalization,
and iteration-budget exhaustion. Before importing DSPy, the Python sidecar
requires a clean git checkout at tag `3.2.1` and commit `29448ae…`, verifies all
296 canonical manifest files, then confirms that ReAct and Tool resolve from
that checkout. It binds the installed distribution version separately from
DSPy's historical `3.2.0` module version, so a fake package or matching version
string cannot pass. The Elixir launcher removes credential-bearing environment
variables before process start; Python scrubs again before import, disables
dotenv, and checks a dummy canary is absent during every queued LM call.

This is C2 operational evidence. The deterministic LM supplies every action,
the retry and idempotency state machines belong to fixture tools, and the
timeout is an injected exception rather than a wall-clock cancellation test.
Therefore the artifact is not evidence for model recovery quality, retrieval
quality, native retry/idempotency features, latency, transport timeouts, or
research effectiveness parity. Its validator recomputes rows, summaries,
limitations, source hashes, and exact scenario order instead of trusting pass
booleans.

```sh
mix imp.benchmark.rag_tool_agent \
  --live \
  --model anthropic:claude-haiku-4-5-20251001 \
  --dspy-model anthropic/claude-haiku-4-5-20251001 \
  --env-file .env \
  --python tmp/dspy-parity-venv/bin/python \
  --out benchmarks/runs/rag-tool-agent
```

Live mode adds one retrieval-conditioned answer and one ReAct lookup row under
matched model identity, provider-equivalent wire APIs, effective generation
controls, exact outputs/traces, and complete provider-reported usage. Imp uses
its reserved `submit` tool while DSPy ReAct uses `finish`; the artifact records
and admits only that explicit runtime adaptation under one semantic prompt
contract. The Imp row imports an MCP catalog tool. `LIVE_PROVIDER=1 mix
live.check` separately proves the same provider/ReAct composition through an
HTTP MCP JSON-RPC server. `full_rag_tool_agent_parity` remains false unless all
provider-free and live rows pass. Quota or provider errors are retained as
failed evidence, never converted into missing or passing rows.

The tracked pre-cutover run under `benchmarks/results/rag-tool-agent-live/`
binds the runner to commit `7105b5e63d326a0cdae5086ed9ff91d56c41ca4d`,
uses `claude-haiku-4-5-20251001` over Anthropic Messages on both runtimes, and
passes 15/15 rows. The two matched live rows record exact answers and traces,
complete provider usage, and about $0.0076 total cost. It is historical evidence
for that revision, not current-release admission or research-scale retrieval or
tool-use quality. Fresh candidates are written under
`benchmarks/runs/rag-tool-agent/`.

## Run RLM Benchmark Parity

```sh
mix benchmark.rlm.check
```

This command runs T0 deterministic contract replay over two hand-authored,
HotPotQA-shaped rows. It verifies that the local Imp and Python DSPy harnesses
execute their scripted paths and records traces for inspection. Gold-derived
outputs, tiny contexts, and intentionally different traces mean this artifact
does not prove effectiveness, long-context behavior, operational parity, or
statistical uncertainty. The release RLM lane requires a separate T3
paper-protocol artifact.

For matched provider-free operational semantics against the current DSPy RLM:

```sh
scripts/setup_dspy_parity_env.sh
uv pip install --target tmp/dspy-current-target --no-deps 'dspy==3.3.0b1'
mix benchmark.rlm.contract.check
```

This T1 suite executes twelve required cases in both Imp and DSPy 3.3.0b1:
persistent state, typed submission, safe transformations, single and
programmatic-loop subqueries, ordered batches, exact and atomic call accounting,
submit repair, extraction fallback, and trajectory retention. The artifact pins
the installed upstream source SHA256 and declares Imp's symbolic `recurse/2`
helper as an extension. T1 proves matched execution semantics only; it does not
measure long-context effectiveness and cannot satisfy the T3 release lane.

## Run Live Benchmark Smoke

```sh
OPENAI_API_KEY=... OPENAI_MODEL=... mix benchmark.live.check
```

This fetches two fresh rows from GSM8K and HotPotQA, runs Imp programs against
a live provider, and writes a run artifact under `benchmarks/runs/benchmark/`.

## Run Imp vs DSPy Parity

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

This runs Imp and the real Python `dspy` package over the same fetched GSM8K
and HotPotQA rows, using the same OpenAI-compatible model. For reproducible
evidence, set `OPENAI_MODEL` or pass `--model` with a provider model id you have
verified in the current account. If neither is set, Imp queries the
OpenAI-compatible `/models` endpoint and auto-selects only when exactly one
text-generation-looking candidate is visible. If discovery fails, returns no
candidate, or returns multiple candidates, the task stops and asks for an
explicit `--model`; it does not invent a fallback model or choose among paid
models on the operator's behalf.

The parity report records:

- Imp and DSPy versions/runtime metadata
- benchmark prompt/signature contract identity for each runtime
- requested and effective generation settings, including endpoint route
  evidence
- task scores and aggregate score delta
- task latency and Imp/DSPy latency ratio
- error counts
- row-level pass/fail agreement and answers
- bounded disagreement examples and per-task disagreement direction counts
- evidence scale: `smoke`, `research_sample`, or `full`

This is the required lane for parity claims. Imp-only benchmark truth proves
Imp behavior; parity requires the Python DSPy sidecar.

The Python runner is a direct OTP Port executable in its own session and
process group. If the campaign caller exits or `--dspy-timeout-ms` expires, the
Port owner sends checked TERM to the complete group, probes group liveness
through a bounded grace period even if the Python leader has already exited,
and sends checked KILL to any surviving descendants. Combined stdout/stderr is
kept as a 256 KiB tail with explicit byte-count and truncation metadata, which
preserves the final `DSPY_REPORT_PATH` sentinel without allowing output floods
to grow BEAM memory without bound. Diagnostics are redacted with the configured
`--api-key-env` value before task errors are logged. Python provider exceptions
are likewise persisted as bounded, redacted error records rather than raw
exception representations. A completed report is atomically promoted from its
`.partial` path; cancellation cannot promote a partial DSPy report.

Two rows are a smoke test, not a leaderboard. They prove only that both sides
can run against the same data and endpoint. Use research samples or the full
lane before making quality/efficiency claims:

```sh
mix imp.benchmark.fetch --tasks gsm8k,hotpotqa --length 200 --out benchmarks/data
mix imp.benchmark.parity \
  --gsm8k benchmarks/data/gsm8k-test-0-200.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-200.jsonl \
  --max-examples 200 \
  --models "$CURRENT_LOW_COST_MODEL,$FRONTIER_SANITY_MODEL"
```

OpenAI is the default parity provider. For another provider, make both sides
explicit so the artifact proves a matched operational path instead of an
accidental OpenAI-shaped comparison:

```sh
PROVIDER_API_KEY=... mix imp.benchmark.parity \
  --gsm8k benchmarks/data/gsm8k-test-0-200.jsonl \
  --hotpotqa benchmarks/data/hotpotqa-validation-0-200.jsonl \
  --max-examples 200 \
  --model "$IMP_PROVIDER_MODEL" \
  --dspy-model "$IMP_DSPY_MODEL" \
  --api-key-env PROVIDER_API_KEY
```

The Imp side takes a ReqLLM model spec such as `anthropic:...` or
`google:...`; the DSPy side takes the matching LiteLLM/DSPy model name such as
`anthropic/...` or `gemini/...`. The artifact records both wire API families so
the live matrix can reject endpoint mismatches.

The intentionally expensive full live row lane is:

```sh
OPENAI_API_KEY=... mix benchmark.parity.full
```

That command fetches GSM8K test and HotPotQA distractor validation in full, then
runs Imp and Python DSPy over the same rows. It can take a long time and spend
real provider money. Its artifacts can support the live matched-model part of a
full parity claim, but not the entire claim by themselves. Use
`PARITY_VALIDATION_PROGRAM.md` for the complete standard.

## Aggregate Live Model Matrix

```sh
mix benchmark.live_matrix
```

This consumes existing `imp-dspy-parity-campaign-*.json` artifacts and writes
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
lanes, Imp has not yet proven live matched model parity. Each model row and
live-lane blocker reports covered rows,
remaining rows, percent coverage, and estimated remaining/full Imp-plus-DSPy
tokens so staged campaigns can be planned from the dashboard instead of hand
calculated. Cost is token-only by default; set
`IMP_BENCH_INPUT_USD_PER_1M` and `IMP_BENCH_OUTPUT_USD_PER_1M` when you want
the matrix to include USD estimates from current provider pricing.

When a lane has multiple candidate models, the lane-level `coverage` and `cost`
headline the strongest candidate because one satisfying model is sufficient for
that lane. The same objects retain a nested `cumulative` summary so operator
dashboards can still see total evidence and spend across all candidates.

The selected artifact for a model must also carry the current Imp benchmark
prompt contract compiled into the benchmark truth runner. Older artifacts
remain valuable history, but they are not release evidence after the task prompt
or signature contract changes. The matrix exposes this as
`summary.prompt_contract.complete`, and the dashboard reports
`prompt_contract_incomplete` until every selected live model lane is current.

When a dataset contract changes or a fresh full campaign supersedes older
smoke evidence, filter the matrix to the intended lineage:

```sh
IMP_BENCH_CAMPAIGN_ID=req-llm-current-low-cost-full-YYYYMMDD \
  mix benchmark.live_matrix
```

The lower-level task also accepts `--campaign-id`. This prevents invalidated
artifacts from winning matrix selection merely because they contain more rows
from an older benchmark contract.

For operationally safer full runs, execute fixed-size chunks with `--offset`
and `--max-examples`, then preserve every emitted artifact:

```sh
mix imp.benchmark.parity \
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
mix imp.benchmark.parity.campaign \
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
For example, Anthropic uses `--model anthropic:claude-haiku-4-5` on the Imp
side and `--dspy-model anthropic/claude-haiku-4-5` on the Python DSPy side.
Do not pass the ReqLLM colon form as `--dspy-model`; omit the flag when the
default Imp mapper can derive the matching LiteLLM id.

For measured transport A/B checks, configure ReqLLM's Finch pool before startup
through the same runner:

```sh
mix imp.benchmark.parity.campaign \
  --model "$IMP_PROVIDER_MODEL" \
  --dspy-model "$IMP_DSPY_MODEL" \
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

The parity runner records its effective pool topology even when no pool flags
are passed. Its HTTP/1 default is one shard with `size` equal to
`--max-concurrency`. This preserves the requested parallel capacity without
randomly queueing colliding requests behind one-connection shards. Explicit
pool flags remain authoritative. The campaign driver applies this configuration
before starting ReqLLM; applying it after application startup does not rebuild
the already-running Finch pool.

Each new Imp row also records ReqLLM request time and Finch request, queue,
connect, send, and receive counts and durations. These fields are process-local
and contain no headers, URLs, request bodies, or credentials. Use them to decide
whether a latency difference is provider time, pool contention, connection
setup, or retries before paying for a larger campaign.

### ReqLLM HTTP/1 latency root cause (2026-07-14)

The completed 8,724-row current-low-cost campaign established close quality
parity but reported an Imp/DSPy latency ratio of `1.765`. Runner-order splits
were similar, so order bias did not explain the gap. Its ReqLLM pool used the
upstream default of eight HTTP/1 shards with one connection per shard.

A provider-free 80-request test with eight concurrent delayed responses held
total connection capacity constant. The `8 x 1` topology took `1,624.0 ms`
with `48.095 ms` mean queue time; `1 x 8` took `1,014.8 ms` with `0.101 ms`
mean queue time. Finch documents that multiple HTTP/1 shards can scatter work
and reduce connection reuse.

A paid A/B/B/A crossover then ran the same 16 HotPotQA rows and matched model
under both runner orders:

| Pool | Runner order | Imp ms | DSPy ms | Ratio | Mean Finch queue ms |
| --- | --- | ---: | ---: | ---: | ---: |
| `8 x 1` | Imp first | 7,789.403 | 3,583.527 | 2.174 | 1,392.365 |
| `1 x 8` | DSPy first | 4,474.305 | 5,069.463 | 0.883 | 1.384 |
| `1 x 8` | Imp first | 4,244.587 | 4,943.526 | 0.859 | 1.547 |
| `8 x 1` | DSPy first | 4,545.958 | 3,014.296 | 1.508 | 540.644 |

Every trial recorded 16 ReqLLM lifecycles, 16 Finch requests, and zero runner
errors, ruling out hidden retries. The four paired trials cost `$0.144541` in
provider-reported usage. Their raw artifacts live under
`benchmarks/results/latency-root-cause/`. This diagnoses and fixes the harness
defect; it does not retroactively turn the historical full campaign's latency
outcome green. A future full claim must use a fresh campaign id and the recorded
effective `1 x concurrency` topology.

Historical-metric annotation (2026-07-19, dee-c2ur): the per-row
`official_hotpotqa_f1`/`official_hotpotqa_em` values inside these four artifacts
were computed with the PRE-parity-port normalization (punctuation→space, no NFD)
on BOTH arms. They remain valid as latency diagnostics — the artifacts' purpose —
but their metric columns are not comparable to post-dee-c2ur scores. They are
deliberately left unedited (historical evidence is immutable); any future metric
claim must recompute from a fresh campaign.

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

Current parity rows retain provider-reported input tokens, output tokens, and
USD cost independently for Imp and DSPy. Imp attributes ReqLLM telemetry in
the row process; the Python side attributes DSPy LM history by canonical row
input. Aggregation marks usage complete only when both runtimes have numeric
usage for every accepted row. The live matrix then projects remaining and full
campaign spend from the observed per-row averages. Its environment-based token
model remains an explicit fallback for legacy artifacts. Run a bounded
current-model tranche and inspect this projection before approving a full paid
campaign.

The live matrix separates evidence completion from experimental outcome. The
`frontier_sanity` lane is complete when a fresh, error-free, matched sample has
at least 200 accepted rows and complete score, latency, prompt-contract, and
generation evidence. Its `parity_outcome` remains `parity_not_established` when
the predeclared score or latency threshold misses. This does not weaken the
threshold or create a parity claim; it prevents repeated paid sampling from
being used to shop for a passing result. Full current-low-cost parity still
requires full accepted coverage and all strict parity checks.

If a live chunk produces runner/API errors, the campaign runner halts after that
chunk instead of continuing to spend provider calls. Any rows with complete
Imp/DSPy evidence are preserved, but quota/rate-limit failures remain
incomplete evidence, not negative benchmark rows. Fix provider
quota/credentials or switch to a matched provider/model lane, then rerun the
same campaign id to continue from the earliest missing accepted row.

Use `--dspy-model responses/<model>` when the matching Python DSPy/LiteLLM path
must force OpenAI Responses endpoint semantics for the selected model. The
runner normalizes that shorthand to LiteLLM's provider-qualified
`openai/responses/<model>` identity. Imp reaches the provider through ReqLLM;
the explicit DSPy model route prevents comparing Responses semantics against
Chat Completions semantics by accident.

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
parallel on both the Imp and Python DSPy sides. It does not reduce the number
of benchmark rows or provider calls, and reports record `max_concurrency` so
serial and concurrent artifacts are auditable. Campaign aggregates require one
consistent `max_concurrency` value before `full_parity` can be true; the live
matrix and dashboard surface mixed or missing concurrency evidence as a release
blocker because latency and throughput claims are not comparable otherwise.

Aggregate chunk artifacts into a campaign report:

```sh
mix imp.benchmark.parity.aggregate \
  --provider req_llm \
  --model "$CURRENT_LOW_COST_MODEL" \
  --in "benchmarks/runs/parity/imp-dspy-parity-${CURRENT_LOW_COST_MODEL}-*.json" \
  --max-concurrency 8
```

The aggregator counts each `(task, absolute_index)` once, so overlapping smoke
or retry chunks cannot inflate coverage. It also scopes reports by Imp provider
and model, so historical direct-client artifacts cannot be mixed into ReqLLM
campaigns. Runner/API error rows are incomplete evidence: they are not included
in coverage or scores, and a newer incomplete row cannot replace an older
complete row for the same canonical index. This matters for quota/rate-limit
failures, where an attempted chunk may produce row shells without valid model
answers. Those rows stay rerunnable and appear as `runner_error_rows` and
missing ranges instead of being treated as both-failed parity rows. It reports:

- total covered rows versus canonical expected rows
- per-task covered rows, missing ranges, incomplete rows, and runner-error rows
- weighted Imp/DSPy scores from row-level pass/fail outcomes
- aggregate and task score gaps
- latency ratio from covered chunk artifacts
- runtime instrumentation summaries: Imp LM call counts, LM-duration share,
  local overhead, fallback/retry counts, prompt size, raw output size, and
  DSPy-side input/message/raw-size diagnostics. The benchmark-local DSPy LM
  captures the exact history entry in worker-local storage before each call
  returns, so concurrent usage and cost do not depend on shared-list append
  order or prompt-text matching. `history_attribution` records
  `thread_local_lm`; `shared_history_match` remains a compatibility fallback.
  `message_chars` uses `row_estimate` only when no attributable entry exists.
- explicit `full_parity: true/false`

`full_parity` is false unless every canonical row is covered, the prompt
contract and effective generation settings are consistent, complete, and
matched, `max_concurrency` is consistent across the campaign evidence, aggregate
and per-task score gaps are within the configured strict thresholds, and the
Imp/DSPy latency ratio is within the configured `--max-latency-ratio` threshold
(`1.5` by default). Latency is part of the decision because parity is about
operational behavior, not only answer quality.

Historical checked-in campaign artifacts may be useful diagnostics, but they are
not release proof unless the live matrix selects them under the current prompt
contract, model-lane policy, effective generation settings, and concurrency
requirements. Treat stale named-model campaigns as prior evidence, not as a
template for new operator commands.

Use the `imp_instrumentation`, `dspy_instrumentation`, and `runtime_shape`
summaries before optimizing runtime code. When Imp `lm_duration_share` is close
to `1.0`, the observed live latency is dominated by the provider/model call
rather than Imp adapter parsing or metric evaluation. Large Imp-vs-DSPy
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
was unavailable. New live evidence should also report
`history_attribution=thread_local_lm`; the shared-history fallback is not
sufficient for a complete concurrent cost claim.

## Evidence Standard

### Test-only operations diagnostic

`mix benchmark.operations_stress.check` is deliberately outside the evidence
and claim system. It runs ten useful single-process deterministic assertions,
but its timestamped JSON does not bind a git tree, RunContext, environment, or
tamper checksum. The artifact declares `test_only_diagnostic` and
`claim_eligible: false`; it must not be admitted or cited at any C0-C5 level.
The same behaviors remain mechanically covered by ExUnit. Operational evidence
must come from a source-bound lane such as failure recovery or overhead.

A credible Imp benchmark report must include:

- dataset manifest SHA256 digests
- train/dev/test or offset/length split description
- model/provider/version metadata
- prompt/signature contract identity
- requested and effective generation settings
- Imp git SHA
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

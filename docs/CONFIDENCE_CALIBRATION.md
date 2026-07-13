# Confidence And Calibration

DSEx keeps constrained-label token confidence, optimization quality, and
empirical calibration separate.

`DSEx.Confidence` extracts `raw_confidence = exp(joint_logprob)` for the
selected JSON enum value. This uncalibrated model score is available in metric
diagnostics and reflective feedback. It is never a maximized GEPA objective.

The GEPA adapter exposes two separate objectives:

- `accuracy` is `1.0` for a correct label and `0.0` otherwise.
- `confidence_quality` is the configured correctness-aware scoring strategy's
  output in `[0, 1]`. Every incorrect label receives `0.0`, regardless of raw
  confidence.

The default quality score follows the pinned upstream
`LinearBlendScoring(threshold=0.99, min_score=0.3)`. Correct predictions at or
above the threshold receive `1.0`; below it, quality is
`0.3 + 0.7 * raw_confidence / 0.99`. Incorrect predictions receive `0.0`.
Threshold and sigmoid strategies use their documented upstream formulas and
also assign every incorrect prediction `0.0`.

The pinned upstream ConfidenceAdapter additionally exports raw probability as
a Pareto objective. DSEx intentionally does not copy that unsafe behavior: a
confidently wrong prediction must not survive solely because it is confident.

## Held-Out Calibration

`DSEx.Confidence.Calibration` reports:

- Brier score and expected calibration error;
- fixed-width reliability buckets;
- coverage, accuracy, and risk under confidence abstention;
- per-prompt reports and maximum descriptive prompt drift; and
- fixed-bin empirical mappings fitted on a separate calibration split.

Every record requires an evaluation `id` and a stable `source_id`. Evaluation
and source IDs must each be unique within a split. Calibration and held-out
evaluation IDs, source IDs, and optional `group_id` values must be disjoint.
Caller-added prompt namespaces therefore cannot hide source leakage.

Histogram summaries expose sample class balance, all bin occupancies, supported
bin counts, and the complete mapping. A fit is marked non-authoritative when it
has only correct outcomes, only wrong outcomes, a one-bin configuration, fewer
than two occupied bins, or fewer than two bins meeting `min_bin_size`.
Non-authoritative fits remain inspectable but cannot calibrate a score or
produce a held-out calibrated report. Held-out scores in unsupported bins also
fail closed.

Here, `authoritative?` only means that these structural degeneracy checks pass.
It does not make a small fixture representative of a deployment population.

Brier score is the primary correctness-aware calibration metric:
`mean((p(correct) - correctness_indicator)^2)`. Its range is `[0, 1]` and
lower is better. Raw and calibrated Brier scores are computed on the same
held-out records while accuracy remains a separate metric. The artifact records
the signed change and labels the observed result `improved`, `regressed`, or
`tied`; calibration is not declared beneficial merely because a mapping was
fitted.

## Live Probe

The default provider-backed probe uses the immutable
`openai:gpt-4.1-mini-2025-04-14` model pin. Load the repository `.env` into the
process without printing it, then run:

```console
set -a
source .env
set +a
mix dsex.benchmark.confidence_calibration --bins 10 --min-bin-size 5
```

The checked-in live dataset is a deterministic 200/200 subset of the public
`CogComp/trec` fine-label question-classification dataset. It preserves the
exact human-assigned label from the source file. Calibration rows come only
from the official train file; held-out rows come only from the official TREC-10
test file. Source IDs bind the source split, pinned file digest, and row number.
Group IDs hash case-folded, whitespace-normalized question text. The builder
deduplicates groups and excludes every test question whose group occurs
anywhere in train, including train rows outside the selected calibration
subset.

`benchmarks/data/build_confidence_calibration_trec.py` fails closed unless the
original CogComp source files match their pinned SHA-256 digests. The generated
provenance manifest binds the loader revision, complete 50-label ordering,
selection seed, split contract, source digests, row counts, and serialized data
digest. Re-running the builder with the same arguments produces the same JSONL
bytes.

The task requires returned OpenAI Chat token logprobs and records the effective
model, API, usage, raw metrics, fit diagnostics, complete mapping, authority
gates, and Brier comparison. Authority requires verified source labels, unique
evaluation and source IDs, source/group split disjointness, at least 100 records
per split, mixed outcomes in both splits, at least two supported calibration
bins, an authoritative fit, a complete held-out calibrated report, and a proper
correctness-aware metric comparison. A negative Brier result still passes the
evidence gates and remains negative.

## July 13 Evidence

`benchmarks/results/confidence-calibration-live-20260713T225422Z.json` is the
fresh authoritative run. All gates passed:

- calibration outcomes: 142 correct, 58 incorrect;
- calibration occupancy: 7 occupied bins, 6 supported bins;
- held-out outcomes: 157 correct, 43 incorrect (`78.5%` accuracy);
- raw Brier: `0.1719157093`;
- calibrated Brier: `0.1395662834`;
- observed Brier reduction: `0.0323494259` (`18.82%` relative);
- raw/calibrated ECE: `0.1760264110` / `0.0565014663`; and
- provider usage: 315,472 input tokens, 2,911 output tokens, `$0.130857`.

The result is positive on this held-out subset. It is not inferred from ECE or
from a degenerate zero score: both fit and evaluation have mixed outcomes, and
the Brier score is a proper correctness-aware metric. The artifact reports an
observed held-out point estimate, not a population-level significance claim.
Each prompt has 100 held-out sources; prompt drift remains descriptive because
those source sets are disjoint rather than paired.

The earlier July 13 support-routing fixture was all correct and used a one-bin
mapping. Its zero post-calibration Brier score and ECE are not evidence of
learned calibration. The retained
`benchmarks/results/confidence-calibration-assessment-20260713.json` records the
rejection and source-run digests; it is superseded as calibration evidence, not
rewritten as a successful result.

This remains a narrow operational probe. It does not establish calibration on
other datasets, prompts, providers, model versions, or deployment populations.
TREC is public and may have appeared in model training data. Deployments must
fit and evaluate on their own source- and group-disjoint data.

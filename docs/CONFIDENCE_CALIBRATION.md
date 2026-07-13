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

## Live Probe

Run the provider-backed probe with a process-scoped OpenAI key:

```console
OPENAI_API_KEY=... mix dsex.benchmark.confidence_calibration --bins 5 --min-bin-size 2
```

The DSEx-authored support-routing fixture contains 12 calibration and 12
held-out sources with disjoint support-thread groups. Each held-out source is
evaluated once under either the minimal or policy prompt. Prompt drift therefore
compares disjoint source sets and is descriptive, not a paired causal estimate.

The task requires returned OpenAI Chat token logprobs and records the effective
model, API, usage, raw metrics, fit diagnostics, and mapping. If the observed
calibration outcomes or score distribution are degenerate, the artifact is
labeled `live_raw_confidence_probe_non_authoritative`, sets
`claims.learned_calibration` to `false`, and writes `calibrated_report: null`.

The July 13 live fixture was all correct and used a one-bin mapping. Its zero
post-calibration Brier score and ECE are not evidence of learned calibration;
the retained evidence proves only compatible-provider logprob transport and raw
reliability instrumentation. The checked-in
`benchmarks/results/confidence-calibration-assessment-20260713.json` records the
rejection and source-run digests. No fresh paid run is warranted until a fixture
is likely to provide mixed outcomes and multiple supported confidence bins.

This remains a narrow operational probe. It does not establish calibration on
other datasets, prompts, providers, model versions, or deployment populations.
Deployments must fit and evaluate on their own source- and group-disjoint data.

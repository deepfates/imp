# Confidence Calibration

DSEx keeps constrained-label token confidence and empirical calibration as
different concepts. `DSEx.Confidence` emits `raw_confidence` from the joint
logprob of the selected JSON enum value. It is a model score, not a calibrated
probability.

`DSEx.Confidence.Calibration` provides held-out reliability analysis:

- Brier score and expected calibration error;
- fixed-width reliability buckets;
- coverage, accuracy, and risk under confidence abstention;
- per-prompt reports and maximum prompt drift; and
- fixed-bin empirical calibration fitted on uniquely identified examples.

Histogram evaluation refuses overlapping calibration and held-out IDs. It also
fails when a held-out score falls in a bin without enough calibration evidence,
instead of inventing a probability.

## Live Probe

Run the provider-backed probe with a process-scoped OpenAI key:

```console
OPENAI_API_KEY=... mix dsex.benchmark.confidence_calibration
```

The checked-in fixture has separate calibration and held-out support-routing
examples. Held-out examples are evaluated under two prompts to measure drift.
The task requires returned OpenAI Chat token logprobs and records the effective
model, API, usage, raw metrics, fitted mapping, and calibrated metrics.

This is a narrow operational calibration probe. It does not establish that raw
confidence is calibrated on other datasets, prompts, providers, or model
versions. Deployments should fit and evaluate their own disjoint data and set
abstention thresholds from the resulting coverage-risk table.

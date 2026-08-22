# Failure and recovery evidence

The canonical failure campaign exercises Imp runtime behavior through public
Elixir APIs. It does not substitute benchmark-only recovery implementations for
the production paths.

## Deterministic authority

`mix benchmark.failure_campaign.check` runs ten iterations of cancellation,
explicit task timeout, bounded concurrency, terminal partial-stream failure,
training HTTP retry/idempotency, HTTP retrieval recovery, MCP recovery, and
exact MIPROv2 and SIMBA checkpoint resume/tamper rejection.

The artifact records process, port, supervised task, admission queue, and
telemetry-handler deltas. It also records balanced telemetry span counts and a
credential scan. Any failed iteration, nonzero added resource count, unbalanced
span, retained handler, or credential hit keeps deterministic authority red.

## Selected local operational authority

The operational campaign is intentionally local, bounded, and provider-free:

* The provider-shaped row starts an operation through Imp's retry boundary,
  forces the first attempt to exceed its attempt timeout, and completes the
  second attempt. It requires exactly two attempts, one observed timeout, a
  stable dummy idempotency key, a terminal 2xx, and an elapsed time within the
  declared deadline.
* The integration row injects one closed retriever transport, then recovers.
  A static-LM ReAct workflow calls `lookup`; the tool returns one recoverable
  error, succeeds on the exact retry, and then calls `submit` exactly once. The
  complete normalized history is part of the verified evidence.

The artifact validator verifies the run envelope, recomputes every deterministic and
operational row from outcomes, and ignores reported summary booleans. At least two
iterations, zero flakes, zero resource leaks, balanced telemetry, and a clean
dummy-canary scan are required for full evidence. The canonical task requires a
clean current-source checkout by default, and the validator rejects dirty or
non-reproducible RunContext envelopes even when their Git revision matches.

This campaign makes no provider, paid-training, public MCP, external-network,
or comparative-performance claim. These are explicit limitations, not implicit
passes.

## Reproduction

Use the pinned settings in `benchmarks/config/failure-recovery-live.json` from
a clean commit. Despite the retained compatibility flag name, `--live` enables
only the local operational rows and performs no external network calls:

```bash
mix imp.benchmark.failure_campaign \
  --iterations 10 \
  --max-concurrency 2 \
  --live \
  --live-iterations 2 \
  --live-timeout-ms 1000 \
  --require-clean \
  --out benchmarks/runs/failure-recovery
```

Then validate and retain the result. The artifact's payload
hash, exact Git revision, clean workspace state, attempt counts, time bounds,
exact tool history, canary digest, telemetry, and resource deltas are the
authority inputs.

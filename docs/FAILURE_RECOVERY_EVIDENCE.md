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

## Selected live authority

The live campaign is intentionally narrower than “every external integration”:

* The provider row injects one HTTP 429, then completes the same idempotent
  operation against OpenAI. It requires exactly two attempts, a stable
  idempotency key, a bounded timeout, positive token usage, and a real 2xx
  response.
* The integration row injects one closed transport into the HTTP retriever,
  then completes against `httpbin.org`. It separately requires a real
  OpenAI-backed ReAct run to invoke `lookup` once and `submit` once.

The dashboard verifies the run envelope, recomputes every deterministic and
live row from outcomes, and ignores reported summary booleans. At least two live
iterations, zero flakes, zero resource leaks, balanced telemetry, and a clean
secret scan are required for full evidence.

This campaign does **not** claim a paid training job lifecycle, a public MCP
service probe, or exhaustive provider/network failure coverage. Agent token
usage is not currently exposed by the final ReAct prediction, so its exact cost
is reported as unavailable rather than estimated. These are explicit
limitations, not implicit passes.

## Reproduction

Use the pinned settings in
`benchmarks/config/failure-recovery-live.json` from a clean commit:

```bash
mix imp.benchmark.failure_campaign \
  --iterations 10 \
  --max-concurrency 2 \
  --live \
  --live-iterations 2 \
  --live-timeout-ms 30000 \
  --model gpt-4.1-mini \
  --agent-model gpt-5.4 \
  --require-clean \
  --out benchmarks/runs/failure-recovery
```

Then point the dashboard at the result directory. The artifact’s signed payload
hash, exact Git revision, workspace state, provider/model names, attempt counts,
time bounds, usage, and resource deltas are the authority inputs.

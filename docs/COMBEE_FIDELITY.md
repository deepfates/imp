# ComBee-Style GEPA Aggregation Fidelity

DSEx implements a BEAM-native ComBee-style reflection aggregation policy. It is
an independent implementation of the algorithm described in the ComBee paper,
not a port of hidden or unreleased GEPA code.

## Authorities and limits

Primary design authority:

- ComBee, arXiv:2604.04247v1, especially `sections/design_v4.tex` in the source
  release.
- The GEPA project post, [Scaling GEPA with
  Combee](https://gepa-ai.github.io/gepa/blog/2026/04/09/gepa-at-scale-with-combee/).
- GEPA commit `92dadfffbe98c8ecf508179a1cab09c1bb85cd32` for the repository state
  audited during implementation.

The pinned GEPA tree contains the April 2026 post and its figures, but no
visible ComBee aggregation or controller implementation. Therefore exact
implementation parity with GEPA cannot be established from that source. DSEx
claims structural fidelity to the published algorithm and documents its
runtime adaptations below.

## Paper-specified behavior

For `n > 0` component-specific reflection records, DSEx:

1. Sets `k = floor(sqrt(n))` from the original record count.
2. Makes `p` total copies of every record, with `p = 2` by default.
3. Shuffles the augmented records from a seed derived from the optimizer seed,
   iteration, component, source count, and duplication factor.
4. Splits the shuffled records into `k` balanced groups whose sizes differ by
   at most one.
5. Calls the first-level reducer for every group under supervised BEAM tasks.
6. Orders intermediate updates by group index and calls one final reducer.

Every reducer receives the unchanged current candidate and selected component.
Arity-five proposers also receive metadata with `phase: :first_level` or
`phase: :final`. Arity-four proposers remain supported; final records contain
`ComBeeGroupIndex` and `ComBeeIntermediateUpdate` fields.

The reflection-call reservation for one component is exactly `k + 1`. The
duplication factor changes reducer input sizes, not the reservation. Reports
record actual dispatched calls: a terminal first-level failure can consume less
than the reservation because queued groups are never launched. An empty
reflective dataset fails without a model call.

The built-in no-LM fallback is phase-aware and exhaustive. It includes every
record in a first-level group and every ordered intermediate update at the final
level. It does not apply a record-count truncation. When a configured reflection
LM returns an error or an invalid response, proposal generation fails closed;
DSEx does not silently substitute the fallback.

## Runtime batch controller

The paper's controller runs one synchronized trial iteration at each candidate
batch size, measures end-to-end delay, converts it to epoch time, fits a power
law, and selects the plateau where marginal improvement reaches 1.6% of the
peak slope. DSEx now executes those trials as ordinary GEPA iterations through
the staged parent, reflection, and child pipeline. Trial candidates can be
accepted or rejected, iteration numbers advance, callbacks fire, and metric and
reflection calls are reserved and charged to the same budgets as later work.

The v1 source does not publish its default candidate values. DSEx therefore
uses the explicit `:candidate_batch_sizes` list when supplied. Otherwise it uses
the documented DSEx adaptation `[min, 2 * min, 4 * min]`, deduplicated after
clamping to the configured maximum and trainset size. The source contains a
commented 200 upper-bound expression rather than a normative constant; DSEx
retains 200 as a tested safety policy, not an upstream parity claim.

For trainset size `N`, both runtime and offline modes compute:

```text
T_epoch(batch_size) = delay * N / batch_size
T_epoch(batch_size) = A * batch_size^-alpha
```

It fits `log(T_epoch) = log(A) - alpha * log(batch_size)`. The default threshold
is `tau = 0.016 * peak_slope`; the plateau is:

```text
plateau_batch_size = (alpha * A / tau)^(1 / (alpha + 1))
```

The integer selection is floored and clamped to the configured range, trainset
size, and DSEx safety cap. Fewer than two successful trials, duplicate batch
sizes, invalid range coverage, a non-positive `alpha`, or a non-finite fit
returns `status: :degenerate` and selects the smallest safe batch. It never
guesses a larger batch after a degenerate fit.

Runtime trials are strictly ordered and never overlap. `:profiling_timeout` is
one absolute monotonic deadline shared by all candidates and every nested GEPA
phase. Completed-trial elapsed time is carried across resume. Before each trial,
DSEx checkpoints controller status `:started`; the normal GEPA phase checkpoints
then persist reservations before dispatch. A clean budget refusal records a
failed trial and all observed call deltas but does not admit its delay to the
fit. Timeout, caller death, crash, or resume from `:started` fails closed because
provider effects are ambiguous.

## Offline measurement mode

Externally collected measurements remain available under the separate
`:offline_measurements` mode. They perform no optimizer work and report
`measurement_source: :caller_supplied`:

## Runtime policy

Example using externally collected measurements:

```elixir
DSEx.Optimizer.GEPA.new(metric,
  generations: 4,
  timeout: 300_000,
  proposal_timeout: 120_000,
  max_reflection_calls: 40,
  combee: [
    duplication_factor: 2,
    max_concurrency: :auto,
    timeout: 60_000,
    batch_controller: [
      mode: :offline_measurements,
      measurements: [{4, 8_200}, {8, 5_100}, {16, 3_400}],
      min_batch_size: 4,
      max_batch_size: 64
    ]
  ]
)
```

Runtime profiling example:

```elixir
DSEx.Optimizer.GEPA.new(metric,
  generations: 5,
  max_metric_calls: 100,
  max_reflection_calls: 40,
  combee: [
    max_concurrency: 4,
    batch_controller: [
      mode: :runtime,
      candidate_batch_sizes: [2, 4, 8],
      max_batch_size: 8,
      profiling_timeout: 120_000
    ]
  ]
)
```

- `proposal_timeout` is distinct from trajectory evaluation timeout. When it
  is omitted, it inherits `timeout` so existing callers receive bounded
  reflection calls.
- Legacy single-call reflection and both ComBee levels run under
  `DSEx.UnlinkedTaskSupervisor`. Each proposal receives one absolute monotonic
  deadline. Nested component aggregation, queued first-level groups, and the
  final level consume the same remaining time. A finite ComBee timeout is an
  additional cap on that inherited proposal deadline.
- The bounded scheduler launches at most the resolved concurrency. On terminal
  failure or deadline it stops launching queued calls, brutally cancels active
  siblings, and marks undispatched work as cancelled. Aggregation reports count
  dispatched provider calls only.
- Timeout, crash, or fatal exit after dispatch consumes the preauthorized call.
  When the inner aggregation returns, a final call is charged only if it was
  dispatched. If an enclosing speculative proposal is killed first, effects
  are ambiguous and the full reservation is conservatively charged.
- ComBee `:auto` concurrency divides `DSEx.Settings.async_max_workers` by the
  resolved speculative `proposal_concurrency`. Explicit combinations exceeding
  that worker allowance are rejected before optimization.
- Callback effects and aggregation reports are applied in proposal-slot and
  component order, regardless of worker completion order.
- Checkpoint schema 4 stores the ComBee configuration identity, an independently
  identity-bound runtime/offline report, pending aggregation reports, and budget
  reservations. Resume rejects drift in seed, duplication, timeout,
  concurrency, candidate schedule, safety range, fit threshold, profiling
  timeout, or offline measurements. A profiling or proposal checkpoint marked
  `started` remains non-resumable because provider effects are ambiguous.

`on_combee_batch_selected` fires after a runtime fit completes or immediately
for an offline fit. Runtime reports use `measurement_source: :runtime_trials`
and include ordered trial iteration, batch, delay, metric calls, reflection
calls, status, and failure reason.
`on_combee_aggregation` exposes `DSEx.Optimizer.GEPA.ComBee.Report`, including
group sizes, source-copy assignments, call counts, status, and deterministic
failure identity. The optimizer report includes resolved policy and ordered
aggregation reports under `metadata.combee`.

## Campaign restart policy

A process already blocked in the old direct `DSEx.LM.generate/3` reflection
path cannot acquire the new task boundary through code reload. Stop that process
and resume from the last completed checkpoint. If the checkpoint predates the
hung reflection, that provider call is an ambiguous external spend and may be
replayed; account for it outside the checkpoint ledger. Both sequential and
parallel-proposal runs checkpoint prepared and started proposal phases with
budget reservations. Resume rejects started work because provider effects are
ambiguous. If an enclosing proposal is interrupted after the started
checkpoint, the full reservation is the conservative spend bound.

## Matched natural-data preflight

Run:

```bash
mix run benchmarks/gepa_combee.exs
```

The default fixture mode compares small-batch aggregation, one naive large
batch, and ComBee on the same first eight rows of DSEx's checked-in GSM8K data.
It reports exact-answer quality/retention, monotonic latency, reducer calls,
fixture token estimates, and provider-free cost. The deterministic fixture run
on 2026-07-13 retained 8/8, 4/8, and 6/8 records respectively with 4, 1, and 3
calls.

Live mode is gated by `COMBEE_PREFLIGHT_MODE=live` and
`COMBEE_LIVE_PROVIDER=1`. The bounded run used pinned
`openai:gpt-4.1-mini-2025-04-14` and is stored at
`benchmarks/results/gepa-combee-preflight-live-20260713T231824Z.json`. All arms
retained 8/8 correct answers. Naive large-batch took 2.62 seconds, 1 call, 755
tokens, and $0.000450; ComBee took 4.25 seconds, 3 calls, 1,909 tokens, and
$0.001228; small-batch took 6.75 seconds, 4 calls, 1,266 tokens, and $0.000841.
Usage and cost came from ReqLLM telemetry.

This is negative quality evidence at the tested scale: eight short records do
not overload the pinned model, so ComBee has no quality deficit to recover and
is slower and more expensive than naive aggregation. The run validates matched
data flow, live calls, and accounting only. It is not a paper replication and
does not support Formula/FiNER quality or speed parity claims.

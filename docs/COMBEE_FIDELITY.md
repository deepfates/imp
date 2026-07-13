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
duplication factor changes reducer input sizes, not the number of reducer calls.
An empty reflective dataset fails without a model call.

## Batch controller

`DSEx.Optimizer.GEPA.ComBee.BatchController` consumes measured
`{batch_size, delay}` pairs. For trainset size `N`, it computes:

```text
T_epoch(batch_size) = delay * N / batch_size
T_epoch(batch_size) = A * batch_size^-alpha
```

It fits `log(T_epoch) = log(A) - alpha * log(batch_size)`. The default threshold
is `tau = 0.016 * peak_slope`; the plateau is:

```text
plateau_batch_size = (alpha * A / tau)^(1 / (alpha + 1))
```

The integer selection is floored and clamped to the configured range, the
trainset size, and DSEx's tested hard cap of 200. The hard cap is a DSEx safety
policy, not a demonstrated upstream constant. Fewer than two measurements,
duplicate batch sizes, invalid range coverage, a non-positive `alpha`, or a
non-finite fit returns `status: :degenerate` and selects the smallest safe
batch. It never guesses a larger batch after a degenerate fit.

## Runtime policy

Example:

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
      measurements: [{4, 8_200}, {8, 5_100}, {16, 3_400}],
      min_batch_size: 4,
      max_batch_size: 64
    ]
  ]
)
```

- `proposal_timeout` is distinct from trajectory evaluation timeout. When it
  is omitted, it inherits `timeout` so existing callers receive bounded
  reflection calls.
- Legacy single-call reflection and both ComBee levels run under
  `DSEx.UnlinkedTaskSupervisor`. A finite ComBee timeout is capped by
  `proposal_timeout`.
- Timeout, crash, or fatal exit after dispatch consumes the preauthorized call.
  When the inner aggregation returns, a final call is charged only if it was
  dispatched. If an enclosing speculative proposal is killed first, effects
  are ambiguous and the full reservation is conservatively charged.
- ComBee `:auto` concurrency divides `DSEx.Settings.async_max_workers` by the
  resolved speculative `proposal_concurrency`. Explicit combinations exceeding
  that worker allowance are rejected before optimization.
- Callback effects and aggregation reports are applied in proposal-slot and
  component order, regardless of worker completion order.
- Checkpoint schema 4 stores a ComBee policy identity, batch-controller report,
  pending aggregation reports, and budget reservations. Resume rejects drift in
  seed, duplication, timeout, concurrency, effective batch, or controller
  measurements. A checkpoint marked `started` remains non-resumable because
  provider effects are ambiguous.

`on_combee_batch_selected` exposes the controller report.
`on_combee_aggregation` exposes `DSEx.Optimizer.GEPA.ComBee.Report`, including
group sizes, source-copy assignments, call counts, status, and deterministic
failure identity. The optimizer report includes resolved policy and ordered
aggregation reports under `metadata.combee`.

## Campaign restart policy

A process already blocked in the old direct `DSEx.LM.generate/3` reflection
path cannot acquire the new task boundary through code reload. Stop that process
and resume from the last completed checkpoint. If the checkpoint predates the
hung reflection, that provider call is an ambiguous external spend and may be
replayed; account for it outside the checkpoint ledger. Parallel-proposal runs
checkpoint prepared/started proposal phases and fail closed on ambiguous
started work; sequential runs checkpoint after the bounded proposal returns.

## Provider-free harness

Run:

```bash
mix run benchmarks/gepa_combee.exs
```

The harness compares one naive large-batch reduction with ComBee using the same
simulated, capacity-limited reducer. It reports monotonic wall time, retained
unique record IDs, and reducer calls. This proves only structural concurrency
and information-retention behavior in the simulation. It is not a paper
replication and makes no quality or speed parity claim without the official
Formula/FiNER datasets, prompts, models, and provider environment.

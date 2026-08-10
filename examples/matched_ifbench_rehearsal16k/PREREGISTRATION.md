# Preregistration: one-seed 16k dress rehearsal (written before launch)

**Date:** 2026-08-09, committed before any paid call of this campaign.
**Campaign:** `matched-ifbench-rehearsal16k-v1` — the contract in this
directory. One seed (2026072705), two optimizer arms per runtime plus
baselines, IFBench source-exact scoring, strict no-fallback OpenRouter routing
(task: openai/gpt-5.4-mini; optimizer: anthropic claude-sonnet-4.6).

**What this is:** an engineering rehearsal of the source-faithful config —
task max_tokens 16384, exactly as the gepa-artifact authors set it
("overriding the dspy defaults", tmp/gepa-artifact/scripts/run_experiments.py:59)
— at ~1/3 of the paper's optimizer budget (GEPA 1200 metric calls of 3,593;
MIPRO 6 candidates / 18 trials), before any Heavy spend. It exercises the
machinery: the redesigned cost guard (p99-4096 reservations, 8192-token
per-call anomaly stop, $60 hard actual-spend cap), the raised optimizer
proposal envelope (2048 tokens), the 6000s matched timeouts, and the ~1/3-paper
budget ceilings.

**What this is NOT:** it claims NOTHING scientifically about v3/gepa014
equivalence, paper reproduction, optimizer effectiveness, or runtime
superiority. One seed cannot support any of those claims and none will be
made from it.

## Predictions (decided before launch, bands from the measured noise model)

The noise model is the gepa014 pilot's measured floor: same-program 64-row
held-out re-evaluations at temperature 1.0 vary by ±0.07–0.11; held-out
completion tokens median 505 / mean 648.

**P1 — Machinery and money.** Every cell (2 runtimes × [baseline + 2
optimizer arms] × 1 seed) completes within its call ceilings with zero
operational stops — no reservation refusal, no completion-token anomaly stop,
no ceiling breach — and total actual spend is ≤ $60 (expected realistic:
$20–50, from pilot per-call actuals × 2–3x token growth at the lifted cap).

**P2 — Runtime agreement (engineering check, not a parity claim).** Per
matched arm, |imp − upstream| held-out mean is within **±0.12** — the
single-seed noise band (upper edge of the measured ±0.07–0.11 same-program
spread, one seed, no repetition). Landing in-band says the harnesses are
measuring the same thing; it does not establish equivalence.

**P3 — Report-only.** Whether either optimizer's champion differs from the
stock program at this budget (any non-stock instruction sealed as champion,
per runtime and arm). No lift band is claimed at n=1; the observation is
recorded for powering the Heavy design, whatever it is.

## Decision rule (committed now)

- **P1 passes and costs are in range** → Heavy contract drafting proceeds
  from this configuration.
- **Any operational stop** (reservation refusal, anomaly stop, ceiling
  breach, transport/route/cost drift, barrier failure) → defect hunt; no
  further paid launches until root-caused.
- P2/P3 outcomes are recorded and disclosed either way; they gate nothing at
  n=1 beyond informing the Heavy noise model.

Whatever the numbers are, they are recorded and disclosed. This file may not
be edited after launch; corrections belong in a dated addendum.

## Addendum 1 (2026-08-09, after stop 1, before relaunch)

Launch 1: both baselines sealed (upstream 0.7917 — reproducing the published
source-sized denominator 0.7874 at the corrected config; imp 0.7031, an
edge-of-noise single-pass watch item), then upstream's GEPA arm died on a
provider-side 503 (litellm ServiceUnavailableError) ~1h in. Root cause: the
contract's zero-retry rule is stricter than pinned DSPy's own default of 3
transient-transport retries (dspy/clients/lm.py:41) — the same
stricter-than-source deviation family as the pilot's 120s timeout. Fixed
symmetrically: num_retries=3 upstream, max_retries: 3 / retry: :transient on
the imp arm. Also fixed a coordinator stop-path bug where the source-binding
check misfires on any stopped record and masks the real stop cause. Spend to
stop: ~$1.50. Predictions unchanged.

## Addendum 2 (2026-08-09, after stop 2, before relaunch)

Launch 2 died deterministically on imp's first baseline row: "invalid
two-stage call envelope". Addendum 1's retry fix was itself defective: in
imp's client the transport-attempt telemetry is emitted only by the explicit
no-retry guard plugin (req_llm.ex enforce_explicit_no_retry — observability
and no-hidden-retries are one mechanism). Setting `retry: :transient` at the
Req layer uninstalled that guard, so NO transport events fired and the
envelope check (messages == responses == transports) refused every row. Note
the initial diagnosis ("retries created extra transport events") was wrong
and is corrected here: transports were missing, not surplus, which is why
the failure was deterministic on row 1 with no provider error present.

Fix, mirroring upstream's ledger semantics exactly (run_upstream.py counts
one adapter_transport_dispatch per logical forward; litellm's num_retries=3
attempts are invisible beneath it): the imp arm reverts to explicit no-retry
at the Req layer (restoring per-attempt telemetry) and performs its 3-retry
transient budget in ObservedLM.dispatch_with_retries/3, where the ledger can
see it. Attempts share a dispatch_tag and merge into ONE transport entry per
logical call with the attempt total disclosed in measurements.count; the
attempts evidence bound widens from ==1 to 1..4 on the imp side only.
Retries apply solely to transport-class failures, never cost/route/contract
stops. Ledger arithmetic (logical == transports) and all ceilings are
unchanged. Shadow preflight (provider-free) passes end to end, including the
one-transport-per-role assertion. Spend to stop 2: ~$0. Predictions
unchanged.

## Addendum 3 (2026-08-09, after stop 3, before relaunch)

Launch 3 ran clean through both baselines and 752/1200 GEPA rollouts
(upstream actual spend $3.68), then stopped on two defects at once:

1. **Optimizer-call ceiling stricter than source (again).** Upstream GEPA
   requested reflection call 25 against our ceiling of 24. The source caps
   nothing but metric calls; our 24 assumed ~1 reflection per iteration, but
   the measured rate is ~2.5 (25 calls by rollout 752), extrapolating to ~40
   at budget exhaustion. Ceiling raised to 96 (~2.4x measured need) in
   contract + upstream expected-ceiling check; transports/total raised
   accordingly (3088). Documented reservation ceiling rises 214.51 -> 228.33
   USD; the actual-spend cap (new_spend_max $60, $30/runtime) is unchanged.
2. **Rescue-path crash planted by the stop-2 fix.** Imp's SIGTERM stopped-
   artifact writer crashed: Jason cannot encode the raw BEAM Reference used
   as the retry dispatch_tag, which rides transport metadata into the
   serialized ledger. The tag is now a unique positive integer. This is why
   no imp-result.json exists for stop 3 (imp spend unrecorded; upstream's
   $3.68 is the observed side).

Predictions unchanged. Cumulative observed rehearsal spend to date: ~$1.50
(stop 1) + ~$0 (stop 2) + $3.68+imp-side (stop 3).

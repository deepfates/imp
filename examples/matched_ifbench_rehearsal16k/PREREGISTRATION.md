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

## Addendum 4 (2026-08-09, preemptive stop of launch 4, before relaunch)

Launch 4 was stopped minutes in (both baselines re-sealed; ~cents of spend)
after a ledger audit of the completed pilot found the next stop before paying
for it: the MIPRO optimizer ceiling of 15 is formula-exact with ZERO margin
(3 data-summary + 2 proposals x 6 candidates; the pilot measured 11 = 3 +
2x4, identically in both runtimes across all three seeds — the formula is
right, but "exactly right" is what the GEPA ceiling was believed to be).
Raised to 24. Documented reservation ceiling 228.33 -> 230.06 USD; actual
spend caps unchanged.

The stop also exposed and fixed a coordinator defect: run_paired.py
installed no signal handler, so an external SIGTERM killed it instantly and
orphaned both peers mid-spend (observed live; the orphans were then
SIGTERMed directly and — verifying the Addendum 3 fix — both wrote clean
rescue artifacts). SIGTERM/SIGINT now route through the existing
BaseException cleanup that stops peers via killpg.

Method note, recorded as a standing lesson: every ceiling in the contract is
now audited against MEASURED ledgers (pilot + stop 3) rather than derivation
alone, and the same audit found no further zero-margin bounds. Lifecycle
behavior (signals, rescue, ceilings) has no fast test today; that suite is
now the acceptance spine of the harness-extraction ticket (imp-6mls).
Predictions unchanged.

## Addendum 5 (2026-08-10, telemetry-only restart, before relaunch)

Take 6 (healthy, ~$1 spent, both baselines sealed at imp 0.8125 / upstream
0.8385 selection) was stopped via the drill-verified signal path solely to
complete live observability, owner-directed: (1) both runners publish 10s
read-only snapshots to run_root/live/*.json (phase, call counts vs ceiling,
spend); (2) the imp GEPA arm registers the engine's OBSERVATIONAL callback
(Imp.Optimizer.GEPA.Callback, return values ignored by design) to publish
live valset scores, mirroring the upstream arm's log-derived live scores.
No budget, model, dataset, or decision-path parameter changes; the callback
cannot alter optimization. Baselines re-run at the same seed (temperature-1
sampling means per-take selection means vary within the measured ±0.08 s.e.;
0.67-0.84 observed across takes is consistent with that noise, and no
single-cell number is interpreted alone). Predictions unchanged.

## Addendum 6 (2026-08-10, after stop 7, before relaunch)

Take 7 (healthy: both baselines sealed at imp 0.750 / upstream 0.745; both
GEPA arms ~10% through budget with live candidates above baseline; $12.17
spent) was killed by the upstream arm's launch-commit re-admission guard —
correctly. The operator committed observatory (dashboard-only) changes to
the repository during the live run; HEAD moved five commits off the pinned
launch commit and the guard refused to continue. The guard, both rescue
paths, and the coordinated stop all worked as designed. Rule adopted and
recorded: the repository is FROZEN (no commits) between launch and terminal
for every live run; observability work batches before launch or after
terminal. Also fixed: the rescue validator's per-runtime reservation-cap
literal still encoded the pre-Addendum-4 ceiling (107.25504 -> 115.03104);
a full sweep of every Decimal literal in the paired surfaces verified the
remainder against current arithmetic. Predictions unchanged.

## Addendum 7 (2026-08-10, after stop 8, before relaunch)

Take 8 delivered the campaign's first substantive result before stopping:
BOTH GEPA arms sealed at the source-faithful budget. Selection champions:
imp 0.8542 vs upstream 0.8698 (delta -0.016, well inside the ±0.09 band) —
matched GEPA optimization parity on selection, from baselines of 0.8229 /
0.7083 (both within the established per-take sampling noise). Upstream's
17-candidate trial ledger and imp's 39-trial ledger sealed intact.

The stop: imp's MIPROv2 REFUSED trials=18 by declared fidelity boundary
("pinned DSPy 3.2.1/Optuna 4.9.0 startup fidelity supports at most 9
objective trials after the baseline; modeled TPE is not implemented",
mipro_v2.ex:1097). This is a genuine, honestly-declared parity gap in the
port — the benchmark surfacing exactly what it exists to surface — not a
harness defect. The pilot's trials=8 sat under the boundary, which is why
it never fired. Design amendment: MIPRO trials 18 -> 9 for BOTH arms (the
largest budget both runtimes can run faithfully; matched design over
budget ambition), ceilings/reservations recomputed (mipro task 928,
campaign reservation 204.62592). The modeled-TPE gap is ticketed as a
prerequisite for paper-scale MIPRO in the Heavy campaign. Take-8 spend:
$13.06. Predictions unchanged; P2's GEPA leg is already satisfied at
selection pending held-out.

## Addendum 8 (2026-08-10, after stop 9, before any relaunch)

Take 9 died at GEPA rollout 1120/1200 (93%, 3h17m, $11.97) on cost-evidence
drift of 1.4e-6 USD against an absolute tolerance of 1.0e-6: OpenAI's
implicit prompt caching activates on the long repeated prefixes that evolved
GEPA prompts become, and its cache-read line items round differently
(~1e-6 scale) between req_llm's computed cost and OpenRouter's billed cost.
The reconciliation guard is now relative (0.5% of call cost, still orders
of magnitude tighter than any real misroute/overbilling) instead of an
absolute millionth tighter than the providers agree with themselves.
Deterministic-in-late-GEPA once caching engages; take 8's differing evolved
prompts are why it sealed. Also disclosed: extraction testing found
run_imp.exs:407 discards reconcile_cost!'s return, so imp's LAST-RESort
actual-spend cap was unenforced this whole campaign (upstream's mirror
raises); the enforced pre-dispatch reservation guard bounded spend
throughout. Fixed in the same patch: the reconcile error now propagates as
the operational stop it was designed to be. Predictions unchanged.

## Addendum 9 (2026-08-10, after stop 10, before relaunch)

Take 10 died at GEPA rollout 800/1200 (67%, $7.63) from an OPERATOR-SIDE
cause with no bearing on the science: the supervising Claude Code session
crashed, and its process-group teardown SIGTERMed the coordinator, which
gracefully stopped both peers. The stop machinery worked exactly as
drilled — both rescue artifacts written, ledgers coherent, no orphans.

Nothing was recoverable, by design: both arms run cache: false with no
GEPA checkpoint path, because pinned gepa v0.1.4 does not persist its
evaluation cache across runs and matched design requires imp to match
that. The lost work is therefore a fidelity cost, not a defect — and a
live demonstration of the resume-economics claim already preregistered
as a separate question (imp-94ax): imp HAS durable checkpointing; the
matched harness deliberately declines to use it.

Operational fix adopted (no contract change): the coordinator now
launches in its own session (os.setsid) so no supervising-tool crash can
kill a multi-hour paid run again. Cumulative campaign spend $51.50;
take 11 lands ~$65, inside the owner-approved envelope for the completed
rehearsal. Predictions unchanged.

## Addendum 10 (2026-08-20, terminal disposition of take 11)

Take 11 sealed all six optimization-and-selection cells: baseline, GEPA, and
MIPROv2 for both Imp and pinned DSPy. The two result ledgers record a combined
actual cost of `$16.416918`. This establishes the bounded engineering path
through optimizer execution and selection; it does not establish held-out
optimizer effectiveness.

The campaign stopped on the first Imp held-out response whose provider usage
reported 4,243 input tokens. The contract's task evidence check allowed at
most 4,096 input tokens even though the same contract reserved 4,864 input
tokens for task-call cost. The request and response completed successfully,
but the post-response evidence guard raised an operational-safety error;
upstream then stopped coordinately. Consequently P1 failed, P2 was not
evaluated on held-out data, and no held-out paired analysis exists.

This addendum also withdraws Addendum 7's phrase "matched GEPA optimization
parity." The Imp value there was the optimizer's internal maximum over noisy
trials, while the upstream value was an independently rescored selected
champion. Those values are not commensurate and establish neither parity nor
non-parity. The sealed trial ledgers and selection identities remain valid
engineering evidence.

The complete take-11 root is archived as
`evidence/matched/matched_ifbench_rehearsal16k-stop11-heldout-input-envelope.tar.zst`
with SHA-256
`993d086c5c05a406ff7f1f19cae229e6d6d1d6cb2323fd7dd09766f32a02ba6e`.
Any successor must be separately named and must reconcile the contradictory
4,096 evidence bound and 4,864 reservation before provider work. It may not
reinterpret take 11 as a completed held-out result.

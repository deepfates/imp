# Preregistration: gepa014 matched pilot (written before launch)

**Date:** 2026-08-09, committed before any paid call of this launch.
**Campaign:** `matched-gepa-mipro-ifbench-dspy321-gepa014-successor-v1` — the
sealed contract in this directory. Three seeds (2026072705–07), two optimizer
arms per runtime (GEPA v0.1.4-merge profile, MIPROv2-Heavy shape) plus
baselines, IFBench source-exact scoring, strict no-fallback OpenRouter routing
(task: openai/gpt-5.4-mini; optimizer: anthropic claude-sonnet), pre-dispatch
USD reservation with contract cap `new_spend_max` $74.55 (expected well under:
prior workshop total for this shape was ≤ $7.59).

**Worldview under test:** pinned DSPy/GEPA are replicated results; Imp is a
port of known-working software, so parity is the null hypothesis. A matched
shortfall indicates an Imp implementation defect, not uncertainty about the
method.

## Predictions (decided before launch)

**P1 — Machinery.** Every cell (2 runtimes × [baseline + 2 optimizer arms] ×
3 seeds) completes within its call caps with zero operational stops. Basis:
five historical launch failures each root-caused and fixed; shadow paired run
passed end-to-end today.

**P2 — Arm parity.** Mean absolute difference between Imp and DSPy final
held-out scores, per matched arm, ≤ **0.05**. Basis: the completed matched
baseline denominators put the runtimes within ~0.026 of each other
(0.7619 vs 0.7874 at the source-sized config); selection/test sets at this
size resolve ~0.02/row, so 0.05 allows ~2 rows of noise beyond the known
runtime gap.

**P3 — Lift direction.** Mean optimizer lift over own baseline, per runtime
and arm, in **[−0.02, +0.10]**. Basis: budgets here (80 semantic metric calls
for GEPA; bounded MIPRO trials) are far below the GEPA artifact's 3,593-call
IFBench regime, so large lift is not expected; sustained negative lift beyond
one row of granularity is not expected either for working optimizers.

## Decision rule (committed now)

- All of P1–P3 in-band → the Heavy campaign is funded as **confirmation**;
  its result is reportable whatever it shows.
- P1 fails → operational defect hunt; no further paid launches until fixed.
- P2 or P3 fails → fidelity defect hunt on the out-of-band arm before any
  larger spend; the pilot result is reported as-is either way.

Whatever the numbers are, they are recorded and disclosed. This file may not
be edited after launch; corrections belong in a dated addendum.

## Addendum 1 (2026-08-09, after pilot stop 1, before relaunch)

Pilot launch 1 stopped under P1: imp's 120s per-row timeout killed two
slow-tail calls that upstream (litellm default 6000s) would have waited out;
the severed dispatches tripped the spend-without-evidence consistency check,
which halted both arms cleanly. Per the decision rule this was an operational
defect hunt: the defect is a matched-semantics asymmetry (imp 50x stricter
timeout than the arm it matches), fixed by matching imp to 6000s. Spend to
the stop: single-digit dollars; no scores retained. Predictions P1-P3 and the
decision rule are unchanged for relaunch.

## Addendum 2 (2026-08-09, after pilot stop 2, before relaunch)

Pilot launch 2: both arms sealed baseline and GEPA for seed 2026072705; the
run died in the upstream MIPRO arm when the task model (temperature 1.0)
refused an IFBench prompt on ethics grounds and the contract's max_errors=0
made the single unparseable response fatal. Owner-approved change: refusal
tolerance max_errors=48 (train 16 + selection 32) on BOTH arms symmetrically
- a refused/unparseable row scores 0, matching native dspy.Evaluate and the
GEPA-paper harness semantics (and what both GEPA arms already did within
rollouts). Operational errors (transport, budget, routing) remain fatal, and
per-row failure counts stay in the ledgers, so an asymmetric failure RATE
between arms remains visible and reportable. P1-P3 and the decision rule
unchanged. Cumulative real spend across attempts: ~\$1.50 of the \$74 cap.

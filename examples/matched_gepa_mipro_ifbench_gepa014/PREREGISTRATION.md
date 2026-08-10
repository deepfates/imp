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

## Final verdict (2026-08-09, after completion and adversarial analysis)

The pilot completed: 18/18 cells, both runtimes, three seeds, zero
operational stops, ledgers exact. Scored against the bands:

- **P1 (machinery): PASS.**
- **P2/P3: NOT EVALUABLE AS DESIGNED.** The bands were set tighter than the
  instrument's measured noise floor (same-program 64-row re-evaluations at
  temperature 1.0 vary by ±0.07–0.11; a paired sign test on *identical
  programs* reached p=0.066). This was a preregistration design error.

What the pilot actually established, each point adversarially verified
against raw ledgers by an independent cold-read analysis:

1. **Chain integrity (imp): clean.** Real searches (11 proposal calls and 18
   evolved instructions per MIPRO run), champions byte-match trial winners,
   held-out evaluated exactly the sealed champions.
2. **Runtime fidelity: PASS at row level.** 192 paired held-out rows of the
   identical stock program across runtimes: imp 26↑ / 16↓ / 150 tied,
   p=0.164 — no significant difference.
3. **Neither optimizer demonstrably moved.** Upstream returned stock 9/9
   cells (its apparent lifts are one program sampled twice); imp's two
   evolved champions are noise-equivalent to baseline (paired p=0.076
   excluding the legitimately-stock seed).
4. **Root cause is two sealed config numbers deviating from the bench's own
   intent** (gepa-artifact source): output cap 1024 vs the authors' explicit
   16384 ("overriding the dspy defaults") — 20% of held-out generations hit
   the cap on both runtimes, zeroing ~11% of rows on the novel-constraint
   split the bench exists to measure; and optimizer budget 80 metric calls
   vs the paper's 3,593 — searches cannot resolve candidates through
   temperature-1 noise at 2% of source budget.
5. Analyst-error log, for the record: three interpretive stories (selection
   overfitting; all-noise; champion-parameter drop) were successively
   falsified by deeper reads; a fourth claim (upstream empty-instruction
   seals) rested on a misread. The data never lied; the summaries did.

Decision-rule outcome: P1's pass funds nothing by itself; the Heavy campaign
requires a redesigned contract (source-intent token budget, paper-regime or
explicitly-powered optimizer budget, refusal-tolerant bootstrap, upstream
trial-score sealing) before any further spend. Measured pilot economics for
that design: ~$6 of recorded eval spend for 1,728 scored rows; held-out
output tokens median 505 / mean 648 with 20% capped at 1024, so a 16384 cap
raises realistic cost by roughly 2–3x, not 16x (reservation policy, which
prices worst-case, is the binding constraint to redesign).

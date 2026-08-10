# Heavy campaign design draft (for owner review — not a contract)

Drafted 2026-08-09 from the completed pilot's measured data and the
gepa-artifact source's explicit intent. Every parameter below cites its
basis. Nothing here is sealed; ratifying a successor contract from this
draft is an owner action.

## Corrections from source intent (the two load-bearing ones)

| parameter | pilot (sealed) | source intent | basis |
|---|---|---|---|
| task max_tokens | 1024 | **16384** | gepa-artifact `run_experiments.py:59` ("overriding the dspy defaults"); 20% of pilot held-out generations capped, ~11% of rows zeroed by cap |
| optimizer budget | 80 metric calls (GEPA), 8 full trials (MIPRO) | **3,593 metric calls** (IFBench MIPROv2-Heavy, `experiment_configs.py`) | pilot searches could not resolve candidates through temp-1.0 noise at 2% of source budget |

## Carried forward from the pilot (validated)

- max_errors = row-count tolerance, operational errors fatal (restores DSPy
  default semantics; the pilot's zero-tolerance crash was the deviation).
- Per-call timeout 6000s both arms (litellm default; 120s was a 50x
  asymmetry).
- cache_identity fingerprint + resume_cache: :drop on the imp arm.
- Temperature 1.0, identical 2-stage program, train[0:300]-derived
  selection, novel-constraint held-out: all match source intent — keep.

## New requirements surfaced by the pilot

1. **Upstream trial-score sealing.** The pilot could not adjudicate why
   upstream returned stock 9/9 because its harness seals no per-trial
   scores (imp seals a full candidate report). run_upstream.py must record
   trial params + scores symmetric with imp's `optimizer_report` before the
   Heavy run, or upstream selections remain unauditable.
2. **Refusal-tolerant demo bootstrap.** Both runtimes produced zero demos in
   every pilot cell (bootstrap prompts refused on content grounds), so demo
   search was silently disabled benchmark-wide. Either fix bootstrap refusal
   handling on both arms or preregister the campaign as instruction-only.
3. **Power the bands to the measured noise.** Same-program 64-row cells vary
   ±0.07–0.11 at temp 1.0. Bands must be derived from that floor: paired
   per-row analysis as the primary endpoint, and either ≥3 held-out
   repetitions per cell or a held-out set large enough that the minimum
   detectable effect < the expected optimizer effect at the chosen budget.

## Cost model (measured basis, not guesswork)

Pilot recorded eval spend: ~$5.9 for 1,728 scored rows + compile phases
(~$8 total with all stopped attempts). Held-out output tokens: median 505,
mean 648, 20% capped — so lifting the cap to 16384 raises realistic spend
~2–3x (long tail grows; median doesn't), NOT 16x.

Dominant open design issue: the **pre-dispatch reservation policy** prices
worst-case (max_tokens × price) per call. At 16384 that reserves ~$0.074
per task call — 45x the pilot's realistic per-call cost — making the
reservation ceiling, not actual spend, the binding constraint. Options for
the successor contract (owner decision):
  (a) reserve at a measured p99 output size (e.g. 4096) with a hard fatal
      stop if any call exceeds it — keeps fail-closed cost math, prices
      realistically;
  (b) reserve worst-case and raise the campaign cap accordingly (ceiling
      in the low thousands USD for the paper-scale IFBench pair);
  (c) running-actual reservation with a global cap — loosest, simplest.

Projected realistic actuals (basis: pilot per-call actuals x2.5 token
growth, paper budget 3,593 metric calls x 2 stages x 2 optimizers x 3
seeds x 2 runtimes + held-out): **roughly $150–300** for the full
IFBench Heavy pair. Worst-case reservation at (b): ~$3,200.

## Suggested sequence

1. Land upstream trial sealing + bootstrap refusal handling (code, free).
2. One-seed dress rehearsal at 16384 / paper budget (~$25–50 realistic)
   with bands preregistered off the noise model above.
3. In-band → the full three-seed Heavy pair as confirmation.

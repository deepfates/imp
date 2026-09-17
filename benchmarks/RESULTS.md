# Results

One row per published number. Every row carries the dataset it was measured on,
the dataset's license, the model and provider that produced it, the date, the
commit, and the command. Prose elsewhere in this repository cites a row here
rather than restating a number.

A row is **re-measurable** if a stranger with an API key can run its command and
get a comparable number, and **recomputable** if the command only recomputes
statistics from committed rows. The distinction is not cosmetic: a recomputable
row cannot tell you whether the original measurement was made correctly, only
that the arithmetic on the retained rows is what the doc says it is.

See [docs/BENCHMARKS.md](../docs/BENCHMARKS.md) for what each command needs and
for the claims that cannot be re-measured at all.

## Re-measurable

| # | Number | Dataset (license) | Model | Provider | Date | Commit | Command |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | Zero-shot held-out accuracy `0.30`–`0.50` over 3 repeats (20 held-out of 60 tickets) | `priv/tutorial/support_tickets.json`, 60 rows, sha256 `7ea5ae7a…` (written for this repository; see [SUPPORT_TICKETS_LICENSE.md](../priv/tutorial/SUPPORT_TICKETS_LICENSE.md)) | `gpt-5.4-mini` | OpenRouter route `openai/gpt-5.4-mini` | 2026-08-22 | `88d61a9c` | `OPENAI_API_KEY=… mix run scripts/tutorial_ticket_routing_experiment.exs` |
| R2 | `LabeledFewShot(k: 8)` held-out accuracy `0.95`–`1.00` over the same 3 repeats; per-repeat lift `+0.45`, `+0.65`, `+0.65` | same as R1 | `gpt-5.4-mini` | OpenRouter route `openai/gpt-5.4-mini` | 2026-08-22 | `88d61a9c` | same as R1 |

R1 and R2 come from one execution of one command; they are two numbers from the
same three repeats, not independent measurements. That run used 120 requests,
44,365 tokens and `$0.038819` in provider-priced usage for all three repeats —
about `$0.013` and 8–9 seconds per repeat. No row errored and the in-BEAM cache
was cleared before each repeat, so all 120 calls were live.

Three repeats of a twenty-row evaluation is a coarse instrument. The gap between
the two rows (45–65 points) is far larger than the instrument's resolution
(one row is 5 points), which is why the direction is trustworthy while the exact
endpoints are not.

## Recomputable only

| # | Number | Dataset (license) | Model | Provider | Date | Commit | Command |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R3 | Imp GEPA minus its own baseline, held-out accuracy `+0.4000`, 95% CI `[0.2958, 0.5042]`, Holm-adjusted `p = 0.00020` | TREC fine-grained, 20 train / 40 selection / 80 held-out drawn from `benchmarks/data/confidence-calibration-trec-fine.jsonl` (see [TREC_ATTRIBUTION.md](data/TREC_ATTRIBUTION.md)) | task `gpt-5.4-mini`, optimizer `claude-sonnet-4.6` | OpenRouter | 2026-07-26 | sealed in `examples/matched_instruction_optimizers_trec/contract.json` | `mix run --no-start examples/matched_instruction_optimizers_trec/recompute_compact.exs -- examples/matched_instruction_optimizers_trec/contract.json examples/matched_instruction_optimizers_trec/data/imp-scored-rows.json examples/matched_instruction_optimizers_trec/data/upstream-scored-rows.json examples/matched_instruction_optimizers_trec/data/aggregate-recomputed.json` |
| R4 | Imp MIPROv2 minus its own baseline, held-out accuracy `+0.1458`, 95% CI `[0.0458, 0.2458]`, Holm-adjusted `p = 0.00270` | same as R3 | same as R3 | OpenRouter | 2026-07-26 | same as R3 | same as R3 |
| R5 | Imp GEPA minus pinned DSPy 3.2.1 GEPA, held-out accuracy `-0.0083`, 95% CI `[-0.0458, 0.0292]`, above the preregistered `-0.05` noninferiority margin | same as R3 | same as R3 | OpenRouter | 2026-07-26 | same as R3 | same as R3 |

R3, R4 and R5 are three seeds (`2026072602`, `2026072603`, `2026072604`) of one
sealed experiment that used 6,491 model calls and `$3.13862325`. The command
replays gold-label checks, row scoring, source-clustered bootstrapping, Holm
correction and the noninferiority decision from the committed scored rows. It
does not re-contact a provider. The raw request-level traces (181 MB) were not
published, so nobody outside this repository can check that the committed rows
are what the providers actually returned. See
[docs/CASE_STUDY_TREC.md](../docs/CASE_STUDY_TREC.md).

| # | Number | Dataset (license) | Model | Provider | Date | Commit | Command |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R6 | Optimize Anything on three ReActV2 tool descriptions: held-out mean over 4 untouched requests `0.95` → `1.0` | 4 held-out agent requests written for `examples/deployment` (see [examples/deployment/data/README.md](../examples/deployment/data/README.md)) | task `gpt-5.4-mini`, reflection `claude-sonnet-4.6` | OpenRouter | 2026-08-23 | `8a6ce8fd` | `mix test test/deployment_agent_optimization_example_test.exs` verifies the retained result; reproducing it needs `OPENROUTER_API_KEY` and `examples/deployment/agent_optimization.exs` |

R6 used 72 task requests for `$0.054251` and 3 reflection requests for
`$0.010494`, each under a separate one-dollar hard cap. It is one stochastic
treatment over four held-out requests: a move from 19/20 to 20/20 scoring
points. It establishes that the component-optimization, action-observation,
Artifact and restart path runs end to end. It does not establish agent
effectiveness. The retained result and Artifact are under
`examples/deployment/evidence/`.

## Findings that are not results

These are recorded because deleting them would misrepresent the record. None of
them can be re-measured from this repository: the raw artifacts that diagnosed
them are not all published, and in two cases the machinery that produced them
has since changed. They are dated observations, not standing claims.

| Finding | Date | What was observed |
| --- | --- | --- |
| HotPotQA JSON-GEPA, mean lift `-0.015` over 3 seeds (task `gpt-5.4-mini`, reflection `claude-sonnet-4.6`) | 2026 | A completed treatment that did not improve held-out performance. Its 32 semantic metric calls were tiny beside the GEPA artifact's 6,871 for HotpotQA; the 24-row test moves in 0.042 steps; six strict-adapter parse failures scored zero on one seed. |
| Banking77 modeled-MIPRO, two conditions at `+0.0417` and `+0.0208` (2 of 3 improving seeds each) | 2026 | Both missed the preregistered `≥0.05` bar. Proposals, attached demos and acquisitions were real. The 48-row test and a high baseline explain the resolution limit. |
| Grue stateful-agent GEPA, 0 of 3 seeds improved (local `llama3.2:3b`) | 2026 | Every candidate scored 0.0 on every selection row, so the optimizer had no ranking signal and retained the baseline. The treatment could not answer the question it was posed. |
| IFBench scorer defect | fixed at `8c798d2e` | The scorer represented nested rule arguments incorrectly and used a non-pinned language fallback. Optimizer results produced with the faulty scorer are invalid and were withdrawn, not rescored. |
| Matched IFBench 16k rehearsal | 2026-08-20 | Both runtimes sealed six optimization-and-selection cells at 16384-token settings for `$16.42`, then the campaign stopped in the held-out phase on a 4096-token input bound of our own. It produced no held-out verdict. An earlier draft compared imp `0.8542` against upstream `0.8698`; those are different quantities (an internal champion score versus an independent re-scoring) and the comparison is withdrawn in full. |
| ChatAdapter parse failures dominate per-cell variation | 2026-08-20 | Across takes of the above, upstream logged 0–5 parse failures per 32-row evaluation (mean 8.3%), correlating with the take's mean at `r = -0.84`. Any future outcome on this design must be reported as two numbers, parse rate and score-given-parse. |
| GEPA Pareto pruning divergence | found by the recorded-tape GEPA differential | Ties were broken by an Elixir term-printing artifact rather than upstream's stable discovery order. A score comparison at the power above could not have detected it. Caught by `mix differential.check`, which is free and has no sampling noise. |

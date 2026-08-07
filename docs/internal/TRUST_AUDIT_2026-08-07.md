# Imp Trust Audit — Final Report

**Date:** 2026-08-07 · **Repo:** /Users/deepfates/Hacking/github/deepfates/imp · **HEAD:** e1392a17 · **Refuted findings during adversarial verification:** 0

---

## 1. Verdict: **GO-WITH-CAVEATS — but a hard NO-GO for GEPA runs as currently configured**

The suite, docs, and harness are real. Nothing is theater, nothing is stubbed, the ground truth verifies (clean compile under `--warnings-as-errors`; 2821 tests / 0 failures in 188.5s with transparent, env-gated exclusions), and the project is conspicuously honest about its own gaps. You can trust the *machinery*.

What you cannot trust yet is **any new GEPA/optimizer number produced with default settings**, because of a composed defect chain in core evaluation:

> **30s default per-row kill timeout → killed rows silently scored 0.0 → those 0.0s durably written to a disk cache keyed only on (candidate text, example) — no model, no metric, no config — and replayed on resume.**

On any slow model, this chain manufactures fake score deflation and then makes it *permanent and invisible*. Both links are confirmed against code (`lib/imp/optimizer/gepa.ex:161`, `lib/imp/optimizer/trajectory.ex:1300-1306`, `lib/imp/optimizer/gepa/evaluation_cache/disk.ex:242-255`).

**Trust:** the offline suite, the docs (two isolated snippet bugs aside), the livebooks, the completed TREC matched result (recomputes byte-for-byte, hashes verify), and the matched IFBench *baselines*.

**Distrust until fixed:** any fresh GEPA benchmark with default timeout + disk cache; any IFBench *optimizer-lift* number (zero completed runs exist — every attempt across four run series ended `status=stopped`); any Heavy result, which will be first-of-kind on a pipeline whose last two fidelity repairs landed within ~36 hours of HEAD.

---

## 2. Per-Dimension Trust Grades

| Dimension | Grade | One-liner |
|---|---|---|
| Ground truth (compile/test) | **solid** | Clean compile, 2821 tests / 0 failures, exclusions deliberate and documented |
| Test-theater | **solid** | Prompt-sensitive Static LM proves optimizer lift causally; real HTTP servers; byte-level DSPy tape parity |
| Docs-vs-code | **mostly-solid** | ~15 snippets executed as documented; TREC recomputation reproduces exactly; 2 broken snippets in ADVANCED.md only |
| Livebooks | **solid** | All 5 execute end-to-end offline; live cells self-gate correctly |
| Bench-harness | **mostly-solid** | TREC contract rigorous and verified; IFBench matched pipeline has never completed a run |
| Core-correctness | **shaky** | Timeout→0.0→cache poisoning chain; deadline semantics bugs; unkeyed disk cache |
| Tickets-process | **mostly-solid** | Scrupulously honest; but flagship Heavy cell has zero outcomes and HEAD sits mid-repair-churn |
| DSPy-parity | **solid** | Every claimed surface substantially implemented; effectiveness gaps self-declared in CONFORMANCE.md |

---

## 3. Blockers (all adversarially confirmed)

### B1. GEPA silently scores timed-out rows as 0.0, with a 30-second default
`lib/imp/optimizer/gepa.ex:161` defaults `timeout: 30_000`, wired through ProgramAdapter into the trajectory runner (whose own bare default is **5s**, `trajectory.ex:1080`). Rows exceeding it are killed via `on_timeout: :kill_task` and become failed trajectories hard-coded to `score: 0.0` (`trajectory.ex:1300-1306`). The module has **zero logging** — while `Imp.Evaluate` warns loudly for the identical event (`evaluate.ex:~350`), proving the hazard is known elsewhere. On a slow model, every candidate's score is silently deflated and the deflation is indistinguishable from real failure.

### B2. Timeout kills and unclassified errors are cached as *complete* evaluations
Narrowed by verification, but real: the `:complete?` completeness guard (`engine.ex:4470-4473`) is live and correctly paired with Optimize Anything's batch evaluator (`adapter.ex:573`) — but the convention was **never extended to GEPA's ProgramAdapter** (`program_adapter.ex:88-92` sets only `%{metric_calls, failures}`) or the per-example path (`adapter.ex:238` passes `record_completeness?: false`). Classified transient failures (transport/budget/cost/cancellation) fail-closed via `Imp.OperationalSafetyError` and never reach the cache — good. But **timeout kills from B1 are unclassified**, so their 0.0s are durably cached and replayed on resume. B1 + B2 compose into permanent score corruption.

### B3. The flagship matched IFBench optimizer comparison has never completed
Zero completed optimizer outcomes across **four** run series (`tmp/matched_gepa_mipro_ifbench{,_v2,_v3,_gepa014}`), all `status=stopped`, with four distinct unresolved launch failures: (1) v1 upstream `AttributeError` (program lacks `forward`), (2) v3 GEPA API drift (`acceptance_criterion` TypeError), (3) gepa014 Imp-side `Req.TransportError :ssl_not_started` in `verify_models!`, (4) gepa014 version-drift guard tripped because the gepa v0.1.4 git tag ships `pyproject.toml version="0.1.3"` (unreplaced release marker). Both Heavy launches also aborted on **Imp product bugs** (dispatch defect at 6cc f37e8; `max_depth`-into-ReqLLM fidelity leak at 9a8154d5, killing 18 proposal slots pre-transport). Tickets imp-yme4 (in_progress) and imp-88sn (open) state plainly: no effectiveness result has been earned. README IFBench numbers (0.7619 vs 0.7874) are baseline-denominator only — the docs say so honestly.

---

## 4. Majors

1. **Disk cache identity omits everything but candidate text + example** (`disk.ex:242-255`). No LM model, temperature, program structure, demos, adapter, or metric in the key; no config fingerprint on the run_dir; and `:auto` silently enables the disk cache whenever `run_dir` is set (`config.ex:183-184`). Reusing a run_dir after changing model or metric replays stale scores — the seed candidate *always* collides — and self-checksums make contamination undetectable.
2. **`:deadline` silently discards per-row `:timeout`** in both `Imp.Evaluate` (`evaluate.ex:374-387`) and the trajectory runner (`trajectory.ex:1112-1148`, which never even receives the timeout variable). One hung row can consume the entire remaining deadline and starve all later rows into `{:exit, :timeout}` — degrades kill granularity on any deadline-bound run.
3. **Harness stability is ~36 hours old.** The last 60 commits are a repair/record/refreeze churn loop on the matched-benchmark subsystem; three fidelity defects in the matched-treatment path itself (dispatch, GEPA treatment integrity, MIPRO proposal option leak) were each discovered only when live paid runs stopped. The repo's own tickets treat pre-repair numbers as inadmissible. (Note: verification softened the dispatch bug — it was fail-loud, raising `ArgumentError` before any provider call, so no wrong-arm scores ever existed.)
4. **Effectiveness is a self-declared open question.** CONFORMANCE.md marks `optimization.instructions` and `optimization.gepa` as "gap": TREC is task-specific C3 evidence; GEPA HotPotQA three-seed mean F1 lift was **-0.015** with zero positive seeds; Banking77 missed its preregistered bar; IFBench was downgraded after a scorer defect. This is disclosure, not concealment — but it bounds what any single new benchmark can claim.
5. **Two broken snippets in docs/ADVANCED.md** (both fail loudly at construction): the HTTP retriever `response_mapper` example is arity-2 where the schema requires `{:fun, 1}` (`http.ex:45`), and `Imp.Retrievers.Databricks.new/3` is documented but only `new/2` exists (`http.ex:449`). Neither touches benchmark paths.
6. **Sealed raw evidence lives only in gitignored `tmp/`** — the recomputation hashes verify, but the underlying artifacts are one `rm -rf` from gone.

---

## 5. Genuinely Solid (credit where due)

- **The test suite is the opposite of theater.** `Imp.LM.Static` handlers inspect the actual formatted prompt and only answer correctly when the optimizer genuinely changed instructions/demos — optimizer tests prove lift *causally*. Mox is quarantined to one contract file. The real client path is tested against a live local Bandit HTTP server including parse-failure→JSON-fallback retry with telemetry assertions. Error paths (retry/backoff/Retry-After, hung-LM cancellation, secret redaction, silent-failure regressions) are unusually deep. DSPy parity is enforced byte-for-byte against pinned DSPy 3.2.1 capture tapes.
- **Docs were verified by execution, not inspection.** ~15 representative snippets ran as documented; the CASE_STUDY_TREC recomputation command reproduced its documented output line byte-for-byte with matching SHA-256; `mix docs` builds; every module named in prose exists.
- **All 5 livebooks execute end-to-end offline**, with live cells self-gating correctly.
- **The TREC matched contract is trustworthy**: exact-provider route guard, identical models both sides, real dspy.evaluate on the DSPy side, failures scored 0 *in the denominator*, loud sentinel failure if the DSPy report is missing.
- **Radical self-honesty**: the project self-reports its invalidated IFBench scorer, preserves pre-fix stopped runs under `-pre-*-fix` suffixes, labels stops "product stop, not scientific evidence," and keeps version claims consistent (unpublished 0.3.0 candidate everywhere).
- **Fail-closed transient-failure design**: classified transport/budget/cost/cancellation errors raise `OperationalSafetyError` before any Result exists — the "LM 500s poison the cache" scenario is already defused for classified errors.

---

## 6. Punch-List Before Real Runs (ordered)

**Must-fix before any paid GEPA run:**

1. **Neutralize B1 for benchmarks now**: pass an explicit generous `timeout:` (or `:infinity`) in every benchmark config — one-line config change, do it today. Then fix properly: add a loud `Logger.warning` on timeout-kill in `trajectory.ex` (mirror `evaluate.ex:350`), and surface killed-row counts in run reports.
2. **Close B2**: extend the `:complete?` convention to `ProgramAdapter` metadata (`program_adapter.ex:88-92`, set `complete?: failures == 0`) and flip `record_completeness?` on the per-example path (`adapter.ex:238`). Until merged, run benchmarks with the disk cache disabled.
3. **Key the disk cache**: add a config fingerprint (model id, params, metric identity, program structure) to `entry_digest/2` in `disk.ex` — or, interim, enforce a fresh `run_dir` per configuration and never resume across config changes.
4. **Fix deadline semantics**: use `min(remaining, timeout)` (with `:infinity` handling) in both wave calls (`evaluate.ex:374-387`, `trajectory.ex:1137-1148`); add a combined timeout+deadline test.

**Must-fix before the IFBench/Heavy campaign:**

5. Repair the four launch failures: start the `:ssl` app before `verify_models!` in `run_imp.exs`; patch or vendored-fix the gepa v0.1.4 checkout's `pyproject.toml` version marker (or relax the drift guard to accept the known tag); adapt the upstream runner to the current GEPA API (`acceptance_criterion`) and the v1 `forward` issue.
6. Launch the restart-only Heavy successor pair from a fresh private root per imp-88sn's mandate — and treat its result as **first-of-kind**, not confirmation.

**Should-do:**

7. Run `mix live.check` (LIVE_PROVIDER=1 with keys) once before trusting real-provider behavior — the 172 excluded live tests have never run in CI.
8. Fix the two ADVANCED.md snippets (arity-1 `response_mapper`; `Databricks.new/2` with full endpoint URL; also reconcile the module's own "new/3" error-message references).
9. Copy sealed evidence out of gitignored `tmp/` into a committed or otherwise durable location.

**Bottom line:** items 1–4 are hours of work, not days, and items 1–2 are the difference between benchmark numbers you can defend and numbers that are quietly wrong on any slow model. Fix those, disable the disk cache for the first real run, then go.
---

## Addendum (round 2, same day) — corrections from adversarial re-review

Line-level facts of the original report all survived spot-checks. Three framing corrections:

1. **"Hard NO-GO for GEPA as currently configured" was overstated.** The flagship matched config (`examples/matched_gepa_mipro_ifbench_gepa014/run_imp.exs`) already passes `timeout: 120_000`, `cache: false`, `max_concurrency: 1` — B1's config mitigation is in place for the campaign path. The library defaults remain the hazard for any other consumer.
2. **The B1+B2 poisoning chain was routed through the wrong backend.** GEPA never uses the Disk evaluation cache (Optimize Anything only). The real carrier is the **checkpoint**: `engine.ex:3396` serializes the in-memory cache (same weak candidate+example-only identity, `memory.ex:21-25`) into every checkpoint; `load_cache` (5352) replays it on resume. Conclusion unchanged, mechanism corrected. Tickets imp-emrr (widened) and imp-g22q cover it.
3. **New matched-fairness defect (was uncovered surface):** cache hits charge zero metric calls (`engine.ex:4307`); combined with checkpoint replay, a resumed Imp arm re-scores for free while the upstream arm may pay. Ticket imp-fwfe. Conversely, failed/timeout-killed rows charge full price (`program_adapter.ex:89`), so B1's deflation compounds with budget burn.

Surfaces examined and found solid in round 2: concurrency admission (`tasks.ex` — FIFO backpressure, lease transfer, no self-deadlock), sandbox (`sandbox.ex` — whitelist ops, atom-exhaustion guard), telemetry redaction. Fifth preflight failure mode noted on imp-nbyg (`String.to_float/1` on catalog prices).

Round-2 cold-reader and DSPy-user findings are tracked as tickets imp-cg5h, imp-st1u, imp-k5wi, imp-nnur, imp-cczl, imp-zc94, imp-n9sj, imp-vb1d.

## Addendum (round 3) — release-machinery findings and saturation verdict

New first-order finding: **the audited HEAD has no CI provenance.** Local main is 583 commits ahead of origin (last origin CI run 2026-07-24) — every benchmark-fidelity repair in the last two weeks is CI-unverified. No branch protection exists; the scheduled Evidence lane failed 2026-07-27 and 2026-08-03 untriaged. Ticket imp-fkwy (P0, blocks imp-88sn). The repo is also private with tags stopped at v0.2.1, so the telos's first clause (installable) is structurally unmet — tracked on imp-qoen, widened.

Checked clean in round 3: CI workflow design, mix task catalog (80+ tasks all real), CHANGELOG vs tags, SECURITY/CONTRIBUTING accuracy, licensing (MIT, no vendored DSPy source), identity/. examples/local_* flagged as maintainer-machine-bound evidence rigs, not runnable case studies.

**Saturation verdict:** after three rounds (workflow audit + adversarial verify; first-hand cold-user execution + cold-Elixir-reader + cold-DSPy-migrant + adversarial re-review; release-machinery sweep), remaining unexamined corners (scripts/ one-offs, docs/maintainers prose) are minor-findings territory. The gap between current state and telos is captured in the imp-yme4 ticket graph: 22 open tickets, with imp-88sn (measured usefulness) gated on score-integrity (90uc→g22q, emrr, pk5c, fwfe), harness repair (nbyg), live verification (7aah), and CI provenance (fkwy).

## Correction (round 4, owner pushback)

The report's claim that "the 172 excluded live tests have never run" was **wrong twice**: live-provider runs are abundantly evidenced (admitted instruction_live and multimodal_live artifacts, paid TREC runs, committed live tutorial receipts, LiveBench baselines, live logs), and the excluded count is 195 across all exclusion tags, not 172 live. The true narrow claim: live-tagged tests are excluded from CI aliases, `live.check` covers ~15 tests in 2 files, and no gate-evidence artifact records a live smoke at the current HEAD. imp-7aah rescoped accordingly. Method lesson recorded: negative existence claims ("X never happened") require positive evidence searches; ours only code-read. Separately: 4 calibration-pilot test failures observed during this correction were caused by the audit's own uncommitted files dirtying the tree — the candidate-identity clean-tree guard working as designed, not a product defect.

## Round 5 — campaign-path certainty pass

Resolved the remaining ambiguity about whether the score-integrity tickets gate the benchmark campaign or only library defaults. Verdict: **they gate the campaign.** (1) `raise_on_exception: true` does not intercept timeout kills — `{:exit, :timeout}` is unclassified and becomes a silent 0.0 trajectory even in the flagship config (trajectory.ex:1160-1171); the 120s campaign timeout moderates frequency only. (2) The round-2 claim that `cache: false` neutralizes cache poisoning conflated the LM request cache (which that flag controls) with the GEPA evaluation cache, which defaults on (gepa.ex:124), is not overridden by the campaign, is serialized into checkpoints, and replays on resume — the exact mode Heavy runs (two recorded stops) operate in. imp-90uc, imp-g22q, imp-emrr, imp-fwfe all confirmed on-path.

## Round 6 — worldview correction (with owner) and final gate

The audit's framing of optimizer effectiveness as "an open question the benchmark exists to answer" was corrected by the owner and is wrong as stated. DSPy/GEPA/MIPRO are published, replicated results on these task families; Imp is a port of known-working software. **Parity is the null hypothesis for a faithful port**: a matched deficit indicates an implementation defect, not uncertainty about the method. The repo's historical negatives don't contradict this — they were single-arm, absolute-lift runs on small local models with no DSPy arm; the only true matched head-to-head (TREC) was favorable. The benchmark is confirmation, and readiness work should *drive the probability of parity-or-better up before spending*.

Final campaign gate (imp-88sn deps): score integrity (90uc → g22q, emrr, pk5c, fwfe) · launch repairs (nbyg, +5th preflight mode) · live smoke recorded at HEAD (7aah) · CI provenance (fkwy) · green DSPy differentials at HEAD (sqkr) · bug-or-benign verdicts on historical misses (sa2a) · preregistered in-band pilot (u3af) before Heavy. Docs narrative reframe tracked as imp-pomi (via claims machinery, not prose edits).

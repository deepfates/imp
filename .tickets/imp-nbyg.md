---
id: imp-nbyg
status: in_progress
deps: [imp-90uc, imp-7aah]
links: []
created: 2026-08-07T17:07:55Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [benchmarks, ifbench, harness]
---
# Repair four matched-IFBench launch failures

Zero completed optimizer runs across four series (tmp/matched_gepa_mipro_ifbench{,_v2,_v3,_gepa014}), all status=stopped: (1) v1 upstream AttributeError (program lacks forward); (2) v3 GEPA API drift acceptance_criterion TypeError; (3) gepa014 Req.TransportError :ssl_not_started in run_imp.exs:896 verify_models!; (4) gepa014 drift guard tripped by gepa v0.1.4 tag shipping pyproject version=0.1.3.

## Acceptance Criteria

All four failure modes have fixes or documented workarounds; a smoke launch of both arms passes preflight and reaches first paid call gate.


## Notes

**2026-08-07T17:15:37Z**

ADDITION (r2): fifth preflight failure mode in the same family — run_imp.exs:147-152 uses String.to_float/1 on catalog price fields, crashes on integer-formatted strings like "0".

**2026-08-08T02:05:11Z**

STATUS at HEAD: all five preflight failure modes addressed - (1) :ssl started before verify_models! (landed pre-session at run_imp.exs:299), (2) String.to_float hardened to Float.parse complete-parse (this commit), (3) gepa 0.1.4 stale pyproject marker explicitly declared in gepa014 contract.json (source_distribution_version 0.1.3 vs installed 0.0.27) with run_upstream.py handling, (4)+(5) v1 forward AttributeError and v3 acceptance_criterion TypeError superseded by the sealed gepa014 successor (predecessors permanently stopped, no-reuse). REMAINING AC: smoke launch of both arms to the first-paid-call gate - needs the bootstrap env (python venv, shadow TLS server) and is the natural next session's opening move alongside cache_identity wiring into run_imp.exs (see imp-emrr note).

**2026-08-09T07:14:34Z**

PREFLIGHT BINDINGS LANDED: run_imp.exs GEPA arm now passes cache_identity (campaign/arm/seed/dataset shas) + resume_cache: :drop. OWNER STEP REQUIRED BEFORE SMOKE LAUNCH: contract.json imp_entry sha (c084ba41...) no longer matches run_imp.exs (drift began at 852c34ea price hardening, extended by the parity bindings) — the launch guard will correctly refuse; re-freeze the contract over the repaired runner (single ratification covering price hardening + parity bindings).

**2026-08-10T04:48:16Z**

Rehearsal (matched_ifbench_rehearsal16k) extends this family with three more stricter-than-source stops, all fixed and preregistered as addenda: stop 1 = zero transport retries vs dspy default num_retries=3 (provider 503 fatal ~1h into GEPA); stop 2 = the retry fix itself (Req-level retry: :transient uninstalled the client's no-retry guard plugin — the sole emitter of transport telemetry — so the envelope check refused row 1 with transports MISSING, not surplus; the first 'extra transports' diagnosis was wrong and is corrected in PREREGISTRATION Addendum 2). Final design: 3-retry transient budget in ObservedLM.dispatch_with_retries/3, attempts merged into one ledger entry per logical call via dispatch_tag with the attempt count disclosed, ledger arithmetic unchanged — mirroring upstream, where litellm retries run beneath the per-forward ledger. Take 3 launched 2026-08-09 21:25: both baselines sealed (imp 0.7135 / upstream 0.6719 selection means), GEPA past 128/1200 rollouts. AC exceeded (paid run well past first-call gate). Close when the rehearsal reaches a terminal verdict.

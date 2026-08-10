---
id: imp-6mls
status: open
deps: []
links: [imp-6tg5]
created: 2026-08-10T04:48:01Z
type: benchmarks
priority: 2
assignee: deepfates
parent: imp-yme4
---
# Extract the matched-benchmark harness into one shared instrument

The sealed-contract methodology is right, but the instrument is being re-copied per experiment: run_imp.exs (~1.6k lines: Observer, ObservedLM, envelope/ledger validation, seal writing) and its Python mirror run_upstream.py were copied pilot→rehearsal and will be copied again for Heavy, kept in sync only by comments (a stale num_retries comment already bit us). Extract: (1) the imp-side instrument (Observer, ObservedLM incl. dispatch_with_retries, envelope+ledger validation, seal/stop payloads) into one tested shared module contracts pin by sha; (2) same for the upstream Capture/RecordingLM mirror; (3) contracts become thin frozen data (pins, budgets, models, seeds) + a sha-pinned instrument version; (4) live ledger snapshots as an instrument feature: Observer/Capture atomic-write run_root/live/{imp,upstream}.json every ~10s (trial scores, phase, spend) — keeps the peers-speak-only-via-disk principle (rejected: distributed-node RPC, which would punch an unaudited live channel into a sealed runner), gives the observatory live imp trials + a live spend meter, and crash forensics for free. Acceptance: the Heavy contract is THIN — parameters only, zero copied instrument code — and the observatory reads live+sealed data from the stable format with no per-run parsing.


## Notes

**2026-08-10T06:15:52Z**

TESTING SPINE (from matklad's How to Test, read 2026-08-09; owner-directed): the extracted instrument's defining test is a sans-provider-IO lifecycle suite — the five rehearsal stops were ALL pure coordination logic (retry accounting, rescue serialization, ceiling exhaustion, signal orphaning) that never needed a provider to fail. Shape: one check() that runs coordinator+both-peer state machines against a scripted fake provider, data-driven scenario files (transient 503 mid-arm; SIGTERM mid-optimizer; optimizer/task ceiling exhaustion; parse-fail rows; cost-cap breach), expect-test on the resulting stop/rescue artifacts. The feature under test: 'a campaign either completes or stops cleanly with rescue artifacts under any perturbation' — test that boundary, not the modules. Precedents that must become scenarios: run_paired now installs SIGTERM/SIGINT handlers routing to stop_peer cleanup (was: instant death, orphaned peers mid-spend — observed live at stop 4), verified once by a manual live drill (launch, SIGTERM at bootstrap, assert both rescue artifacts + zero orphans, ~3 cents). Ceiling rule: every contract bound must cite a MEASURED ledger (pilot or prior take) x explicit margin — formula-exact ceilings with zero margin are how stops 3 (gepa 24) and near-miss 4 (mipro 15) happened.

**2026-08-10T14:23:15Z**

Eval throughput: imp's harness evaluates batch phases (baseline/valset/held-out) strictly sequentially because call-envelope attribution windows the ledger before/after each row — while upstream fans out via dspy's thread pool. Measured take 9: GEPA-phase pace is identical (1167 vs 1211 task calls — GEPA is algorithmically sequential on both sides); imp only loses minutes on batch evals. The extracted instrument can have both: the retry dispatch_tag already attributes every transport to its originating call, so rows can run in concurrent Tasks with per-tag attribution instead of windowing — BEAM-native parallel evals with no audit loss.

**2026-08-10T14:27:53Z**

TARGET ARCHITECTURE CORRECTION (owner dialogue 2026-08-10): extraction destination is decided by OWNERSHIP, not convenience. (1) Spend-safe auditable execution — budget reservation, cost caps, call/transport ledger, retry accounting, response evidence — is a missing LIBRARY feature (every production user wants 'run with a $cap + full audit trail'), not harness glue; principled home is lib/imp as a documented, semver'd capability, placement decided by reading the existing Imp.Optimizer.Playbook.Campaign seam first. (2) The paired-experiment protocol (sealed contracts, two-phase, peer coordination) is benchmark tooling: one maintained internal package. (3) Contracts are pure data with all arithmetic derived. (4) Observatory reads a stable artifact format only. The in-flight worktree slice (Observer/CallBudget + lifecycle tests) is the right first motion either way — tests transfer to wherever ownership places the code.

**2026-08-10T14:38:34Z**

EXTRACTION FINDING (slice 2, 2026-08-10): run_imp.exs:407 discards reconcile_cost!'s return — imp's hard actual-spend cap is UNENFORCED (detected, refused internally, ignored); upstream's mirror raises OperationalSafetyAbort on the same condition. Dormant asymmetric safety hole, never surfaced by nine live takes, found by the sans-IO suite's second slice. Disposition: take 9 continues (pre-dispatch reservation guard is intact and bounds worst case; measured spend far under all bounds); shared-module fix = propagate the error into the stop path; rehearsal runner patched post-terminal; disclosed in verdict addendum. Slice rulings for later: rename :r16k_dispatch_tag to an instrument-generic key; drop dead max_input_tokens field from ObservedLM (row-level input guard lives in evidence validation) with a doc note; crash-on-invalid-backoff stays fail-loud. Slices 1-2 verified independently: 11 lifecycle tests, 0 failures, 0.1s, branch harness-extraction in scratchpad clone imp-hx (fetch after unfreeze).

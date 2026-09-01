---
id: imp-6mls
status: open
deps: [imp-v03h]
links: [imp-6tg5]
created: 2026-08-10T04:48:01Z
type: benchmarks
priority: 2
assignee: deepfates
parent: imp-yme4
---
# Build one thin shared instrument for matched benchmark campaigns

The sealed-contract methodology is right, but its implementation has been
copied between campaigns and repeatedly produced coordination, accounting, and
envelope defects. This ticket owns only the research instrument. First consume
the public spend/usage capability from imp-v03h; do not hide a second product
runtime inside benchmark code.

Extract the Imp observer/recording boundary and pinned-DSPy mirror into one
tested internal instrument. Contracts become thin immutable data with derived
arithmetic and a pinned instrument identity. Stable atomic live snapshots and
sealed terminal artifacts support crash forensics and downstream observatory
views without experiment-specific parsing. This precedes further HoVer, Heavy,
IFBench-continuation, observatory, and resume-economics campaigns, but does not
block the ordinary release product loop.

## Acceptance Criteria

The Imp side uses the public budget/usage ledger; provider-free perturbation
tests cover retries, timeout, signal interruption, cap exhaustion, parse
failure, and actual-cost reconciliation; the Python mirror has the same
observable rules; envelope and call-count arithmetic is derived from thin
contracts; a campaign completes or stops with synchronized, checksummed rescue
artifacts and no orphan processes; Heavy and the IFBench continuation contain
parameters only and no copied instrument implementation.


## Notes

**2026-08-10T06:15:52Z**

TESTING SPINE (from matklad's How to Test, read 2026-08-09; owner-directed): the extracted instrument's defining test is a sans-provider-IO lifecycle suite — the five rehearsal stops were ALL pure coordination logic (retry accounting, rescue serialization, ceiling exhaustion, signal orphaning) that never needed a provider to fail. Shape: one check() that runs coordinator+both-peer state machines against a scripted fake provider, data-driven scenario files (transient 503 mid-arm; SIGTERM mid-optimizer; optimizer/task ceiling exhaustion; parse-fail rows; cost-cap breach), expect-test on the resulting stop/rescue artifacts. The feature under test: 'a campaign either completes or stops cleanly with rescue artifacts under any perturbation' — test that boundary, not the modules. Precedents that must become scenarios: run_paired now installs SIGTERM/SIGINT handlers routing to stop_peer cleanup (was: instant death, orphaned peers mid-spend — observed live at stop 4), verified once by a manual live drill (launch, SIGTERM at bootstrap, assert both rescue artifacts + zero orphans, ~3 cents). Ceiling rule: every contract bound must cite a MEASURED ledger (pilot or prior take) x explicit margin — formula-exact ceilings with zero margin are how stops 3 (gepa 24) and near-miss 4 (mipro 15) happened.

**2026-08-10T14:23:15Z**

Eval throughput: imp's harness evaluates batch phases (baseline/valset/held-out) strictly sequentially because call-envelope attribution windows the ledger before/after each row — while upstream fans out via dspy's thread pool. Measured take 9: GEPA-phase pace is identical (1167 vs 1211 task calls — GEPA is algorithmically sequential on both sides); imp only loses minutes on batch evals. The extracted instrument can have both: the retry dispatch_tag already attributes every transport to its originating call, so rows can run in concurrent Tasks with per-tag attribution instead of windowing — BEAM-native parallel evals with no audit loss.

**2026-08-10T14:27:53Z**

TARGET ARCHITECTURE CORRECTION (owner dialogue 2026-08-10): extraction destination is decided by OWNERSHIP, not convenience. (1) Spend-safe auditable execution — budget reservation, cost caps, call/transport ledger, retry accounting, response evidence — is a missing LIBRARY feature (every production user wants 'run with a $cap + full audit trail'), not harness glue; principled home is lib/imp as a documented, semver'd capability, placement decided by reading the existing Imp.Optimizer.Playbook.Campaign seam first. (2) The paired-experiment protocol (sealed contracts, two-phase, peer coordination) is benchmark tooling: one maintained internal package. (3) Contracts are pure data with all arithmetic derived. (4) Observatory reads a stable artifact format only. The in-flight worktree slice (Observer/CallBudget + lifecycle tests) is the right first motion either way — tests transfer to wherever ownership places the code.

**2026-08-10T14:38:34Z**

EXTRACTION FINDING (slice 2, 2026-08-10): run_imp.exs:407 discards reconcile_cost!'s return — imp's hard actual-spend cap is UNENFORCED (detected, refused internally, ignored); upstream's mirror raises OperationalSafetyAbort on the same condition. Dormant asymmetric safety hole, never surfaced by nine live takes, found by the sans-IO suite's second slice. Disposition: take 9 continues (pre-dispatch reservation guard is intact and bounds worst case; measured spend far under all bounds); shared-module fix = propagate the error into the stop path; rehearsal runner patched post-terminal; disclosed in verdict addendum. Slice rulings for later: rename :r16k_dispatch_tag to an instrument-generic key; drop dead max_input_tokens field from ObservedLM (row-level input guard lives in evidence validation) with a doc note; crash-on-invalid-backoff stays fail-loud. Slices 1-2 verified independently: 11 lifecycle tests, 0 failures, 0.1s, branch harness-extraction in scratchpad clone imp-hx (fetch after unfreeze).

**2026-08-10T18:24:25Z**

STATUS 2026-08-10: slices 1-2 landed on branch harness-extraction (now fetched into the main repo as a local branch ref, 6 commits — no longer stranded in a scratchpad clone). Extracted so far: Imp.MatchedInstrument.{CallBudget, Observer, ObservedLM} + a scripted FakeLM, with 11 sans-IO lifecycle tests (0.1s, verified by the principal executing them, not by reading the diff) covering retry-merge accounting, ceiling refusal, USD reservation refusal, cost-cap stop, Jason-encodability of the live snapshot (the stop-3 regression), retry exhaustion, safety-errors-not-retried, seed-drift refusal, and handler-side tag stamping. Rulings recorded: injectable backoff; handler owns dispatch_tag stamping; live_trials initialized; refusals-as-evidence documented; cap message genericized. REMAINING SLICES: response-evidence validation (carrying the reconcile_cost! propagation fix), derived-arithmetic contract loading (kill the six-copy constant problem), the Python Capture/RecordingLM mirror, thin-contract migration of the rehearsal, and tag-attributed parallel batch evaluation.

**2026-09-01T22:44:31Z**

Post-v0.3.2 reconciliation surfaced Dependabot alerts GHSA-m4rf-3fr8-xwx3 (critical) and GHSA-6hwm-xvph-95vm (high) for nltk 3.10.0 in `benchmarks/requirements-ifbench-parity.txt`; both are fixed in 3.10.3. This is an isolated Python benchmark environment, not the Imp package or Haven runtime, and the reported Stanford-wrapper/Graphviz execution paths are not part of the current IFBench treatment. Do not mutate sealed historical locks in place. The shared instrument or a new campaign environment must mint a new source-identified lock at nltk >=3.10.3, revalidate the IFBench scorer and fixtures, and repin any continuing contracts before paid work.

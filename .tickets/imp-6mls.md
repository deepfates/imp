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

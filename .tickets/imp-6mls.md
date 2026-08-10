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


---
id: imp-vb1d
status: open
deps: []
links: []
created: 2026-08-07T17:14:57Z
type: task
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [conformance, honesty, process]
---
# Bind conformance dispositions to asserting tests, not authored labels

CONFORMANCE.md claims to be an 'Executable Upstream Conformance' report, but statuses are hand-declared dispositions in bench/imp/upstream_fidelity.ex (1237-line ledger); the generator only checks evidence files exist (line ~1203) and audits claim registries. Nothing computes :conformant from invariants actually holding — which is how runtime.async_stream_cache stayed 'conformant / missing evidence: none' while streaming silently degrades (imp-nnur). Same failure mode available for all 26 rows.

## Acceptance Criteria

Each row's invariants map to named tests whose passing is required for the status (or report renamed to 'audited ledger' and each hand-judgment labeled as such); a deliberately broken invariant flips its row in the generated report.


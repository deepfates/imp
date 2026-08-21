---
id: imp-2kyx
status: in_progress
deps: [imp-6mls]
links: []
created: 2026-08-10T18:24:10Z
type: ifbench
priority: 2
assignee: deepfates
parent: imp-yme4
---
# Complete a clean held-out continuation from the frozen IFBench champions

Take 11 is terminal and durably archived: all six baseline/GEPA/MIPRO selection
cells were frozen, then held-out evaluation stopped because the harness rejected
a successful 4,243-input-token response against a 4,096 evidence bound even
though the same contract reserved 4,864 input tokens. This is a benchmark
integration defect, not a product failure or scientific optimizer result.

Do not rerun optimization or reinterpret partial held-out work. After the
shared instrument owns coherent derived envelopes and fresh Artifact application
is proven locally, create a parent-bound held-out-only continuation. Reapply the
six frozen champions to fresh Imp and pinned-DSPy programs and reevaluate all
64 held-out rows for all three arms in both runtimes under the unchanged model
treatment. Keep this downstream of ordinary product-path work.

## Acceptance Criteria

A continuation binds the take-11 archive, original manifest/source commit,
selection receipts, and all six artifact hashes; shadow validation proves fresh
application and parameter-name compatibility; all held-out rows are evaluated
fresh for every runtime/arm with zero optimizer calls; row ledgers, parse rate,
score-given-parse, cost, and Artifact application evidence are retained; the
verdict and canonical evidence docs distinguish the terminal take-11 stop from
the continuation result.


## Notes

**2026-08-21T03:23:01Z**

Ledger correction: take 11 completed and sealed all six optimizer arm cells at the source-faithful 16k settings, then stopped during held-out evaluation on Imp's repo-owned 4096 input-token bound. The engineering rehearsal succeeded at its narrow scope, but this ticket's held-out paired analysis and archival acceptance criteria remain unmet, so it stays open.

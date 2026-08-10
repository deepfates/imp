---
id: imp-sg0r
status: closed
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [evidence, durability]
---
# Move sealed benchmark evidence out of gitignored tmp/

Recomputation hashes verify, but sealed raw artifacts for matched runs live only under gitignored tmp/ — one rm -rf from gone.

## Acceptance Criteria

Sealed evidence copied to a committed or otherwise durable versioned location; recomputation docs point there.


## Notes

**2026-08-08T02:32:54Z**

CI PROOF (2026-08-08): UpstreamFidelityTest fails on CI with invalid_evidence==2 — the conformance ledger references 2 evidence files that exist only on the maintainer machine. This ticket is no longer hygiene; it blocks a green fast.check unless the files are committed or the ledger rows downgraded honestly.

**2026-08-08T04:31:03Z**

PARTIAL FIX pushed: the 'machine-local evidence' was three entire untracked protocol test suites (test/protocol_mcp, protocol_retriever, protocol_training) referenced by the claims registry — committed at fc918518, 6/6 passing locally. CI protocol.check had been green against directories it didn't have (skipped-success semantics); it now has real content. Verify invalid_evidence drops to 0 on next CI run; sealed tmp/ artifacts remain this ticket's open scope.

**2026-08-09T06:54:51Z**

Evidence lane GREEN (run 31299539655) after archiving 12 superseded orphaned artifacts per the provenance test's own remedy. Remaining scope: sealed tmp/ raw artifacts durability + MuSiQue dataset re-provisioning (MUSIQUE_DATA_ROOT gate documents the absence).

**2026-08-10T04:49:45Z**

Archived gepa014 pilot + rehearsal stop1/stop2 roots to evidence/matched/*.tar.zst with SHA256SUMS and README (extraction instructions + what each archive is). No docs/EVIDENCE.md exists at HEAD; the PREREGISTRATION.md files are the interpreting docs and the README links the pilot's. Routine going forward (recorded in README): archive each run root at terminal — the live rehearsal root joins on completion.

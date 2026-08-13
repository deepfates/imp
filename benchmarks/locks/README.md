# Immutable per-contract dependency locks

Each sealed experiment pins the exact dependency lock that produced its
evidence, content-addressed by that lock's own sha256 prefix.

These files are **immutable**. A campaign that needs different packages adds a
new snapshot; it never edits one in place.

## Why

`benchmarks/requirements-dspy-3.2.1-optuna-4.9.lock` was shared by several
sealed contracts. On 2026-08-09 commit `027ff2a1` added IFBench scoring
packages to it and repinned only the IFBench contract — silently invalidating
the TREC contract's seal, so the recomputation command published in
`docs/CASE_STUDY_TREC.md` failed with `upstream_dependency_lock SHA-256 drift`
for anyone who tried it (imp-x83e). One mutable file shared by several seals
means any campaign can break another's evidence.

Repinning TREC to the *new* lock would have been a lie: that lock did not
produce the TREC result. Restoring the original content under an immutable
name keeps the seal honest.

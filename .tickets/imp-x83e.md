---
id: imp-x83e
status: open
deps: []
links: []
created: 2026-08-11T17:03:33Z
type: bug
priority: 0
assignee: deepfates
parent: imp-yme4
---
# TREC case study — the repo's strongest result — is not recomputable

docs/CASE_STUDY_TREC.md publishes an exact recomputation command and README points at TREC as the strongest matched result. Running that command today fails:

  ** (ArgumentError) upstream_dependency_lock SHA-256 drift
  contract.exs:952 require! <- validate_runtime_dependencies!

ROOT CAUSE (verified): examples/matched_instruction_optimizers_trec/contract.exs:719 hardcodes lock_sha256 c7e29a1f24... for ../../benchmarks/requirements-dspy-3.2.1-optuna-4.9.lock. That file's actual digest is now 363ae08404... Commit 027ff2a1 (2026-08-09, 'Make the sealed upstream lock actually executable') added missing IFBench scoring deps (defusedxml, nltk, langdetect, emoji, regex...) to the lock and updated the IFBench contract's pin, but NOT TREC's. Two sealed contracts share ONE MUTABLE lock file; repinning it for one campaign silently invalidated the other. Broken since 2026-08-09.

WHY IT IS P0: the epic's acceptance criteria require that 'an independent adversarial consumer can install, exercise, and recompute the strongest claims without relying on workshop context or maintainer machinery.' Right now the single strongest claim (GEPA +0.40 untouched accuracy, MIPROv2 +0.1458, 3 seeds) cannot be recomputed by anyone, including us.

FIX OPTIONS:
 (a) tactical — verify the added packages cannot affect TREC scoring (they are IFBench-only scorers), then repin TREC's expected sha and RE-RUN the documented command end to end to confirm it now prints the documented final line.
 (b) structural, preferred — give each sealed contract its own immutable lock snapshot (e.g. benchmarks/locks/<contract>-<sha>.lock) so no campaign can invalidate another's seal. Same defect class as constants duplicated across surfaces.

ACCEPTANCE: the exact command published in docs/CASE_STUDY_TREC.md runs clean from a fresh checkout and reproduces the documented aggregate; add it to CI so it cannot silently rot again.


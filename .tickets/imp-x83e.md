---
id: imp-x83e
status: closed
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


## Notes

**2026-08-13T01:49:49Z**

FIXED AND VERIFIED 2026-08-11.

Root cause confirmed: commit 027ff2a1 (2026-08-09) edited the SHARED benchmarks/requirements-dspy-3.2.1-optuna-4.9.lock in place to add IFBench scoring packages (defusedxml, nltk, langdetect, emoji, regex...) and repinned only the IFBench contract, invalidating TREC's seal. Broken for 2 days; nobody noticed because no test ran the published command.

FIX (structural, option b): sealed contracts no longer share a mutable lock.
- benchmarks/requirements-dspy-3.2.1-optuna-4.9.lock RESTORED to the exact content TREC's evidence was produced under (sha c7e29a1f...), recovered from 027ff2a1^. TREC's contract.json/contract.exs are UNTOUCHED, so its manifest_sha256 and archived result bindings stay intact.
- The IFBench variant is preserved immutably at benchmarks/locks/dspy-3.2.1-optuna-4.9-ifbench-363ae084.lock; both IFBench contracts (gepa014, rehearsal16k) repointed there. Their campaigns are complete/stopped and not lane-recomputed, so moving them is the cheap side of the trade.
- benchmarks/locks/README.md records the immutability rule and why repinning TREC to the new lock would have been a lie (that lock did not produce the TREC result).

VERIFIED BY EXECUTION, not reasoning:
- The exact command published in docs/CASE_STUDY_TREC.md now prints the exact documented line: 'matched TREC compact recomputation passed: GEPA +0.4000, MIPROv2 +0.1458, GEPA Imp-minus-DSPy -0.0083'.
- IFBench rehearsal shadow preflight still passes end to end (status: pass) on the snapshot path.

REGRESSION GUARD (the acceptance criterion): test/case_study_trec_recomputation_test.exs, provider-free, 0.8s, 2 tests — one runs the published command and asserts the documented line, one asserts docs/CASE_STUDY_TREC.md still documents that same line and still references every input path. Docs and evidence can no longer drift apart silently.

---
id: imp-fkwy
status: in_progress
deps: []
links: []
created: 2026-08-07T17:19:00Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [ci, release, provenance]
---
# Restore CI provenance: push main, green the pipeline before paid runs

Local main is 583 commits ahead of origin; last CI run on origin main 2026-07-24 — every benchmark-fidelity repair at HEAD has zero CI provenance. No branch protection (gh api 404) so CI is advisory even when it runs. Scheduled Evidence lane failed on 2026-07-27 and 2026-08-03, untriaged; two dependabot CI runs also red. The audited HEAD is CI-unverified code.

## Acceptance Criteria

main pushed; CI green at the commit the benchmark campaign runs from; Evidence lane failures triaged to green or the lane's claims withdrawn; branch protection decision recorded.


## Notes

**2026-08-08T02:32:54Z**

STATUS: 7/8 CI jobs green at HEAD (dialyzer, quality/hex-audit incl. bandit CVE bump, package, campaign, protocol, integration, docs — all fixed this session). Last red: fast.check, root causes now fully classified after three fix rounds (dev-env child compile: fixed; zsh missing on runners: fixed; remaining 16 failures = tests requiring the pinned DSPy parity env via scripts/setup_dspy_parity_env.sh, example-project deps prefetch, and 2 conformance evidence files that exist only on the maintainer machine). NEXT MOVES (mechanical): (1) tag the 16 env-dependent tests (@moduletag :dspy_parity) across ~10 files: dspy_gepa_output_alignment, dspy_gepa_trace_semantics, deployment_banking77_mipro_example, matched_instruction_family_ifbench_design, hover_papillon_calibration_pilot, matched_gepa_mipro_ifbench, mipro_v2_optuna_startup_search, mipro_v2_upstream_fewshot, musique_ans_mipro_current, deployment_hotpotqa_gepa_example, dspy_optimizer_public_workflow_gate; (2) add --exclude dspy_parity to fast.check + production test aliases (mix.exs:330,346); (3) create a differential CI job that runs setup_dspy_parity_env.sh + those tests — this doubles as imp-sqkr (differentials at HEAD). (4) UpstreamFidelityTest invalid_evidence==2 on CI = two ledger evidence files are machine-local — identify via Imp.ReproductionRegistry.audit! on a fresh clone; belongs to imp-sg0r.

**2026-08-08T04:34:17Z**

invalid_evidence==2 ROOT CAUSE (verified in a fresh worktree, not guessed): claim.optimizer.mmgrpo.semantic_conformance ('DSPy authority materialization differs at dspy/teleprompt/grpo.py') and claim.optimizer.ensemble.semantic_conformance ('could not read tmp/dspy-3.2.1/tests/teleprompt/test_ensemble.py') — the pinned DSPy 3.2.1 checkout lives in gitignored tmp/, provisioned only by scripts/setup_dspy_parity_env.sh. Same fix as the 16 fast.check failures: the differential CI lane (imp-sqkr) runs the setup script first; fast.check should exclude UpstreamFidelityTest's evidence assertions or the audit should classify absent-authority as 'unavailable' rather than 'invalid'. CORRECTION LOG: my interim claim that test/protocol_* suites were untracked was FALSE (directory-vs-file comparison bug in my check); they are committed and passing. Caught before any commit.

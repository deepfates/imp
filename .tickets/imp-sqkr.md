---
id: imp-sqkr
status: open
deps: [imp-fkwy]
links: [imp-sa2a]
created: 2026-08-07T18:49:14Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [fidelity, differential, benchmarks, readiness]
---
# Green fidelity differentials at the campaign HEAD

Parity with DSPy is the null hypothesis for a faithful port; the strongest pre-run predictor of a favorable matched result is arm-to-arm differential tests (real pinned DSPy 3.2.1 sidecar) passing at the exact commit the campaign runs from. These exist (adapter golden traces, few-shot/weight optimizer differentials, MIPRO/SIMBA structural cases) but nothing gates the campaign on their being green at HEAD — and HEAD has zero CI provenance (imp-fkwy).

## Acceptance Criteria

All differential/conformance suites executed at the campaign commit with results recorded as evidence; any red differential is a filed defect blocking launch.


## Notes

**2026-08-08T02:32:55Z**

SCOPE MERGE (r7): the natural implementation is a dedicated CI differential job that runs scripts/setup_dspy_parity_env.sh then the :dspy_parity-tagged suite (see imp-fkwy note for the 16 tests) — green differentials at HEAD and CI coverage of them become the same artifact.

**2026-08-08T06:44:56Z**

LANE LANDED: :dspy_parity tag across 12 test files, fast.check excludes it (gate contract updated), mix differential.check alias (test env), CI job 'differential.check' provisions parity venv + pinned source + zsh + dev build. Local clean-tree run: 76 tests, 3 failures, all pre-existing environmental facts needing owner decisions: (1) sealed matched_gepa_mipro_ifbench v1 contract fails 'root Mix lock drift' because the bandit CVE bump changed mix.lock — sealed contracts pin the lock hash, so ANY dep bump invalidates historical contract validation at HEAD; decide re-freeze vs historical-seal skip semantics. (2)+(3) musique_ans_mipro_current receipt tests read /tmp/musique-current-data-dir — machine-local data OUTSIDE the repo, absent even here now; needs data re-provisioning or receipt-only validation. CI verdict pending on this push.

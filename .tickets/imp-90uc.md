---
id: imp-90uc
status: closed
deps: []
links: [imp-g22q, imp-emrr, imp-pk5c]
created: 2026-08-07T17:07:36Z
type: bug
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [gepa, evaluation, correctness]
---
# Fix GEPA silent timeout-kill scoring rows as 0.0

gepa.ex:161 defaults timeout: 30_000 (trajectory runner bare default 5s); rows exceeding it are killed (on_timeout: :kill_task) and hard-coded to score 0.0 in trajectory.ex:1300-1306 with ZERO logging, while Imp.Evaluate warns loudly for the identical event (evaluate.ex:~350). On a slow model every candidate score silently deflates and is indistinguishable from real failure.

## Acceptance Criteria

Timeout-killed rows emit Logger.warning mirroring evaluate.ex; killed-row counts surfaced in run reports; benchmark configs pass explicit generous timeout; test covering slow-row kill visibility.


## Notes

**2026-08-07T17:15:37Z**

CORRECTION (r2): flagship config examples/matched_gepa_mipro_ifbench_gepa014/run_imp.exs already passes timeout: 120_000, cache: false, max_concurrency: 1 — strike the 'benchmark configs pass explicit generous timeout' AC bullet (already satisfied; must not close ticket as a no-op). Remaining scope: loud logging on timeout-kill + killed-row counts in reports + test. ALSO STRENGTHENED: failed/killed rows are charged full metric_calls (program_adapter.ex:89), so under slow models score deflation compounds with budget burn on garbage rows.

**2026-08-07T17:58:48Z**

ON-PATH CONFIRMED (r5, first-hand): campaign config's raise_on_exception: true does NOT catch timeout kills — {:exit, :timeout} bypasses raise_if_present! (only OperationalSafetyError raises) and lands in failed/5 score 0.0 (trajectory.ex:1160-1171,1300). Campaign's 120s timeout moderates frequency, not the mechanism. This ticket gates the campaign, not just library defaults.

**2026-08-07T22:52:52Z**

DONE at commit 6b7d3e8a: killed rows warn loudly (per-row + batch summary, mirroring Imp.Evaluate), Trajectory.killed?/1 public, killed: count in ProgramAdapter metadata, API manifest regenerated. Tests: optimizer_trajectory_test (slow-LM kill visibility, fast-path negative).

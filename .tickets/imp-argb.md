---
id: imp-argb
status: in_progress
deps: []
links: []
created: 2026-07-30T22:14:07Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [product, package, public-api]
---
# Ship one honest Imp package center

Obstacle: the stable product center is not yet fully safe and explicit through the ordinary cold-consumer path. Converge the smallest honest package experience without treating it as completion of Imp.

## Acceptance Criteria

From an unpacked package, a consumer defines a typed two-stage Imp.Module through the documented named-predictor callbacks; runs Experiment.check with disjoint train, selection, and test data; receives linked private Result and Artifact files before test access; loads them in a fresh OS process; serves concurrent calls and hot reload; and sees contained timeout, cancellation, and failure. Nested async_max_workers: 1 work completes. GEPA and COPRO refuse absent real proposal sources. SIMBA sends no ambient source by default. Seed zero is honored. A real negative optimizer outcome remains visible and is acceptable. This milestone does not satisfy the epic effectiveness requirement.

## Notes

**2026-07-30 package-safety checkpoint**

The five independently reproduced engine defects are repaired through ordinary
public behavior: nested `Imp.Tasks.async_stream/3` work borrows an existing
single-worker lease without self-deadlock (`c2284d1`); nonzero GEPA and COPRO
runs require a real proposal source (`d71557c`); custom multi-stage programs use
the paired, checked `Imp.Module` named-predictor callbacks (`db220b0`); SIMBA
defaults to structural reflection grounding and reads module source only after
explicit opt-in (`15e8e36`); and BEAM-native MIPRO honors an explicit zero seed
while its named DSPy 3.2.1 fidelity mode retains upstream's falsey-zero behavior
(`88b3266`).

Cold convergence found two additional owning defects. Provider-free GEPA
campaign/profile tests still depended on the removed synthetic proposer, so
they now supply an explicit deterministic reflection LM. Parallel development
compilation expanded a nested HoVer retriever struct before its defining module
was available; runtime struct identity is now checked without compile-time
expansion (`746bde6`). A test-linked BootstrapFewShot cache teardown race is
owned by ExUnit supervision (`063dce7`).

Current-source BootstrapFinetune, mmGRPO, and BetterTogether C1 receipts were
recaptured once without widening their claims. At clean `063dce7`,
`mix fast.check` passed 53 doctests, 9 properties, and 2,649 tests with zero
failures and 11 skips; `mix package.check` passed its unpacked tutorial,
private artifact/result, clean-room VM, release, two-stage concurrent OTP,
failure/cancellation, hot-use, and fresh-process checks; `mix docs.check`,
`mix reproduction.check`, and `mix quality.check` passed. The retained real
Banking77 package example remains an honest negative selection outcome with a
reusable fresh-process artifact. This checkpoint establishes the early package
center only; it does not establish broad optimizer usefulness, semantic
completion of advertised families, or the `imp-yme4` telos.

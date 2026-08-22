---
id: imp-7yim
status: closed
deps: []
links: []
created: 2026-08-22T14:33:28Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [package, consumer, product]
---
# Run an early clean-consumer spine probe

Before the source audits and optimizer-family work grow, use the current distributable package from an isolated project to attempt the shortest central Imp workflow with no workshop context or repository-private fixtures. The purpose is fast product learning: expose installation, terminology, API, documentation, and state-transfer failures while they can still shape the deeper work. This is an early probe, not the final adversarial acceptance pass.

## Acceptance Criteria

From a new temporary Mix project using the built package and public docs, a cold operator can configure a provider or documented deterministic substitute, define and compose a typed program, build examples and a metric, evaluate it, run one ordinary optimizer, inspect the selected result and cost/failure data, write an Artifact, and apply it to freshly reconstructed trusted code; every point requiring repository knowledge or oral inference is recorded in the owning child ticket and repaired or explicitly classified; the probe uses no benchmark-only runner or private fixture and does not claim final release acceptance.

## Notes

**2026-08-22T15:32:35Z**

2026-08-22 current-HEAD early probe: mix imp.package.clean_room --output tmp/early-consumer-spine passed the actual unpacked package, offline consumer compile, provider-free 25% -> 100% scripted LabeledFewShot tutorial, cross-VM Artifact load with fresh runtime credential, tamper rejection, OTP release, selection 0.25 -> 1.0, untouched 1.0, four concurrent calls, crash/timeout containment, and post-failure service. This is strong mechanics/packaging evidence, not yet the AC cold documentation-led natural optimizer story: the shipped tutorial uses deterministic scripted responses and the gate itself encodes expected output. The run exposed one repo-owned deprecated LM-map warning in the loader; replaced it with public Imp.LM.Static.new and re-ran the skip-release package proof cleanly. Keep this ticket in progress for an independently authored docs-only consumer attempt and natural provider optimizer path.

**2026-08-22T15:39:33Z**

Independent package-only cold consumer succeeded from /tmp without source tests/tickets/runners: authored a two-stage Imp.Module, union-shaped labeled rows with disjoint train/selection/test, Static LM, LabeledFewShot Experiment, Report inspection, Artifact write/read/apply to fresh trusted code, and call. Observed selection 0.0 -> 1.0, untouched 1.0, credentials_absent true, mode-0600 19,660-byte artifact, no Imp errors. Remaining product friction: the shortest spine is scattered across docs; named-predictor example projection is unspecified; Static/no-call cost is not represented through one stable result field; Report.best_score nil vs outer admission score is unexplained; k is per predictor but metadata selected_count was 2; reports/artifacts can expose training content and need a sensitivity warning; install remains mutable/heavy. Repair these before closing.

**2026-08-22T15:52:56Z**

Cold-consumer friction repaired in the owning public guide: required vs nullable vs default output semantics now have a runnable structured-signature example; omitted nullable outputs are explicit nil; output defaults round-trip; false/zero/empty values override defaults; ReActV2 stricter submit behavior and BEAM default_factory disposition are stated. This closes that specific ambiguity but not the remaining composed-spine/report/cost/sensitivity/install friction.

**2026-08-22T20:22:02Z**

Closed on current candidate after the independently authored package-only consumer was rerun against a freshly rebuilt 0.3.0 package. It again completed the full two-stage custom Imp.Module -> disjoint Experiment -> LabeledFewShot -> selection/test -> Artifact write/read/apply -> fresh call path, with selection 0.0 -> 1.0 and untouched test 1.0.

The discovered friction is now repaired or classified at its owning boundary: LabeledFewShot documents that k is per predictor, union-shaped examples are projected through each predictor signature, compilation makes zero provider calls, and best_score is nil because it does not score; metadata now names predictor-example assignment counts explicitly. The API Guide points to the Experiment scores, warns that reports/artifacts may contain sensitive demos/instructions/outputs/errors, and already contains the composed named-predictor contract. The built package uses private atomic artifacts and the consumer observed the renamed fields after a clean dependency compile. Source-path mutability is not a package defect: README already requires exact-commit pins until the owner chooses publication.

Verification: 66 focused optimizer/report tests passed; mix imp.package.clean_room passed the unpacked package/tutorial/cross-VM artifact/tamper/release/concurrency/failure lifecycle; /tmp/imp-cold-consumer.LtldUi passed against that rebuilt package (artifact 19,675 bytes). This closes the early probe exactly, not final release acceptance or broad optimizer effectiveness.

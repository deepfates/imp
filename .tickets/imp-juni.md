---
id: imp-juni
status: closed
deps: [imp-n8zn, imp-uhp2]
links: []
created: 2026-08-22T13:38:22Z
type: task
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [package, docs, consumer]
---
# Run an adversarial cold-consumer completion pass

Give the built package and its public documentation to a technically capable consumer with no workshop history or maintainer checkout assumptions. Have them complete several central user stories, record every ambiguity or blocker, repair the product or documentation, and repeat from a clean environment.

## Acceptance Criteria

From an isolated clean consumer project using only the distributable package and public docs, the consumer can configure a provider, define and compose typed programs and tools, build disjoint datasets and metrics, evaluate and optimize representative tasks, inspect results and costs, persist and reload selected state, and run it through a fresh concurrent OTP service; every discovered blocker or misleading instruction is repaired or explicitly scoped; the entire pass is repeated successfully from a new clean environment without repository-private fixtures, secrets, or oral guidance.

## Notes

**2026-08-22T21:30:42Z**

Final adversarial cold-consumer pass at b837fcb9d3c20d4d9f970f50fc6af4a1817f46cc: mix package.check rebuilt the actual 0.3.0 Hex payload, ran 14/14 package-contract tests, then created clean dependency environments using only the unpacked package and public shipped files. The package-only tutorial improved 25%->100%; public construction/evaluation/optimizer/tool/ReAct and optimizer lifecycle contracts passed; separate writer and loader VMs wrote/read/applied a dynamic Artifact, rejected tampering, and executed fresh trusted code; a clean OTP release started and served the selected two-predictor program with four concurrent calls, crash/timeout containment, recovery, and a fresh-process result/artifact link. This is the second independent clean-consumer cycle after closed early probe imp-7yim, whose docs-only consumer exposed and drove repairs to composed predictor projection, result/report meaning, artifact sensitivity, and LabeledFewShot metadata. No new blocker or misleading public instruction surfaced. Dependency compiler warnings are in third-party toml/jaxon, not Imp. Together the early adversarial authorship pass and this clean final package replay satisfy the final consumer boundary without inventing another release harness.

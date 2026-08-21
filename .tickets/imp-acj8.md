---
id: imp-acj8
status: closed
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: bug
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [artifacts, api]
---
# Fix optimizer report atom/string instability across artifact roundtrip

Report.fetch(deployed).optimizer returns :labeled_few_shot on the live program but "labeled_few_shot" (string) after Artifact.write!/read!/apply. LEARNING_PATH §8b documents the atom output, which is falsified by running it verbatim.

## Acceptance Criteria

Type is stable across the roundtrip (or doc receipt corrected and type contract documented); doc output matches actual execution.


## Notes

**2026-08-21T03:22:15Z**

Known public optimizer identities now normalize back to their canonical atoms when Report state loads; unknown extension identifiers remain portable strings. Exact live-vs-Artifact equality and fresh-process package contracts pass (94 focused artifact tests and 14 package tests).

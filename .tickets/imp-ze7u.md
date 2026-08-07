---
id: imp-ze7u
status: open
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: chore
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [testing, honesty]
---
# Rename optimizer_effectiveness_test to reflect plumbing scope

test/optimizer_effectiveness_test.exs pattern-matches the winning prompt string in its Static handler — it proves demo injection and candidate selection (plumbing), not effectiveness. Name overclaims; reserve 'effectiveness' for live-evidence naming per CONFORMANCE.md's own gap declaration.

## Acceptance Criteria

File and test names describe wiring/selection; no offline test carries 'effectiveness' in its name.


---
id: imp-ze7u
status: closed
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


## Notes

**2026-08-21T03:28:53Z**

Renamed the provider-free scripted test to optimizer_selection_wiring_test and its module/tests to describe demo injection, selected instructions, and scripted dev-set selection. Migrated its Static LM to the current struct API. No offline test filename contains effectiveness; focused tests pass.

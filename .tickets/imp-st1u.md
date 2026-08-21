---
id: imp-st1u
status: closed
deps: []
links: []
created: 2026-08-07T17:12:13Z
type: task
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [docs, signatures]
---
# Write a signature type-DSL reference

The signature string mini-language ('ticket -> team: enum[...]', short_span, lists, numbers) has no reference: no doc lists the available types. short_span appears in API_GUIDE and GLOSSARY with zero definition. First-contact concept, undocumented.

## Acceptance Criteria

One canonical table of every signature type with example + validation behavior; linked from README, API_GUIDE, GLOSSARY.


## Notes

**2026-08-21T03:22:15Z**

Added the canonical signature type DSL table to API_GUIDE, including aliases, recursive arrays, enums, answer shapes, validation, map-only code, and unsupported boundaries. README and GLOSSARY link it; documentation contract enforces coverage.

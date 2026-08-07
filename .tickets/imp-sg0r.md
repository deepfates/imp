---
id: imp-sg0r
status: open
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [evidence, durability]
---
# Move sealed benchmark evidence out of gitignored tmp/

Recomputation hashes verify, but sealed raw artifacts for matched runs live only under gitignored tmp/ — one rm -rf from gone.

## Acceptance Criteria

Sealed evidence copied to a committed or otherwise durable versioned location; recomputation docs point there.


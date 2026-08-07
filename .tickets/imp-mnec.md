---
id: imp-mnec
status: open
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [docs, adapters]
---
# Document DSPy-parity prompt format for Elixir users

Rendered prompts tell the model outputs 'must be formatted as a valid Python Literal' — byte-parity with DSPy's chat adapter, undocumented. Anyone inspecting their own traces in an Elixir library will be confused.

## Acceptance Criteria

Adapter docs explain the DSPy-parity wire format and why; front-door doc links to it.


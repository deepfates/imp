---
id: imp-mnec
status: closed
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


## Notes

**2026-08-21T03:28:53Z**

API_GUIDE now explains that Python Literal, list, and dict wording in Chat and JSON prompts deliberately matches pinned DSPy 3.2.1 wire guidance; Imp parses it into Elixir types and never evaluates Python. README links directly to that adapter-wire-format section. Documentation contracts pass.

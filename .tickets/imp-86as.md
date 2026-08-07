---
id: imp-86as
status: open
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: chore
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [docs, livebooks, dx]
---
# Migrate docs/livebooks off deprecated %{module, opts} LM shape

README, LEARNING_PATH §4, livebook 01, IMP_FOR_DSPY_USERS table all teach %{module: Imp.LM.Static, opts: [...]}, which the library itself deprecation-warns on first use ('use an LM struct instead... Support will be removed'). A cold user's first offline exercise hits a deprecation warning. Also: docs never say Static LMs and Imp.dump don't compose (dump raises 'not portable').

## Acceptance Criteria

All teaching surfaces use Imp.LM.Static.new/1; a note where Static meets persistence pointing at rebind/context; grep for the deprecated shape in docs/livebooks returns nothing.


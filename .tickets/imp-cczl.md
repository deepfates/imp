---
id: imp-cczl
status: open
deps: []
links: []
created: 2026-08-07T17:13:23Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [observability, docs, dspy]
---
# Fix inspect_history mapping: no retroactive LM-call history exists

IMP_FOR_DSPY_USERS maps dspy.inspect_history() to Imp.trace/2 as a drop-in, but trace must wrap the call in advance and there is no global last-N LM-call buffer anywhere (observability.ex:69,155; req_llm.ex has no call store). Either build a bounded redacted recent-calls buffer or fix the mapping table to say 'plan ahead'.

## Acceptance Criteria

Mapping table row truthful; if buffer built, it is bounded, redacted by default, and tested.


---
id: imp-cczl
status: closed
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


## Notes

**2026-08-21T03:22:15Z**

Took the documented acceptance path: DSPy migration table and API Guide now say trace must wrap the call in advance and that Imp has no retroactive global last-call buffer. No new buffer or storage semantics were invented.

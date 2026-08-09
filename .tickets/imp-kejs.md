---
id: imp-kejs
status: in_progress
deps: []
links: []
created: 2026-08-08T01:11:39Z
type: bug
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [react, providers, openrouter, live]
---
# ReAct/CodeAct fail on OpenRouter route: unknown_tool nil/'None'

First recorded live.check at HEAD (via OpenRouter, openai/gpt-5.4-mini): 12/15 pass — predict, chain-of-thought, RAG, history, refine all work live. But ReAct fails {:unknown_tool, nil} (live_provider_e2e_test.exs:77,127) and CodeAct {:unknown_tool, "None"} (:295): the model's no-tool/finish signal on this route arrives in a shape imp's tool loop doesn't recognize ('None' is a Python-ism — likely OpenRouter normalization or prompt-format interaction). Also live_provider_test.exs:66 hard-requires OPENAI_API_KEY regardless of IMP_LIVE_PROVIDER — provider-specific test should skip. Campaign impact: IFBench two-stage program uses no ReAct tools, so this does NOT block the matched campaign — but it blocks any agent benchmark and contradicts the react conformance row.

## Acceptance Criteria

ReAct/CodeAct live tests pass via OpenRouter; nil/'None' tool signals handled per DSPy semantics or rejected with a clear provider-route diagnostic; README-hero live test skips under non-openai providers; gate evidence recorded green.


---
id: imp-cg5h
status: closed
deps: []
links: []
created: 2026-08-07T17:12:13Z
type: task
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [docs, adoption]
---
# Rewrite README for the cold Elixir reader

Cold-reader test (senior Elixir dev, no DSPy): sentence 1 defines Imp via DSPy (null reference for them); 'optimizer'/'compile' used 5+ times before being defined ('compile' collides with BEAM compilation); first example front-loads adapter+json_retries; the 'What the current evidence says' section is lab-notebook density (GEPA/MIPROv2/TREC/preregistered bars) that nearly loses the reader, and what they CAN parse is discouraging. Missing entirely: the baseline being improved on — hand-written prompt + regex-parse code shown next to the Imp version. 'Programming, not prompting' is asserted, never argued.

## Acceptance Criteria

README opens with a self-contained definition and a before/after vs hand-prompting; evidence section becomes a 3-sentence honest summary linking to docs/EVIDENCE.md; a cold Elixir reader hits no undefined term in the first screen.


## Notes

**2026-08-21T03:26:21Z**

README now opens with a self-contained Elixir definition, contrasts a hand-built ReqLLM prompt/parser/validation path with one typed Imp program, and reduces the evidence section to three honest sentences linking the canonical evidence guide. Documentation and learning-path contracts pass.

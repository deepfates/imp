---
id: imp-nnur
status: closed
deps: []
links: []
created: 2026-08-07T17:13:23Z
type: feature
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [streaming, conformance, honesty]
---
# Make streaming honest: real tokens beyond bare Predict, fix conformance row

Imp.Streaming.stream/3 defaults to running the program to completion then re-chunking the string grapheme-by-grapheme (fake streaming, streaming.ex:12-47); provider_stream: true only reaches programs resolving to bare Predict; composed modules silently fall back. Yet CONFORMANCE runtime.async_stream_cache is marked conformant with 'missing evidence: none' while models.normalized_runtime_prerelease admits the LMStream runtime type is missing — conformant-by-generosity. A DSPy user's streaming chat UX over composed modules does not port and nothing warns them.

## Acceptance Criteria

Provider streaming reaches composed programs (or fallback is loud+documented); conformance row downgraded/justified; streaming docs state exactly what streams when.


## Notes

**2026-08-21T03:22:15Z**

Chose the allowed loud-fallback disposition. `provider_stream: true` now returns terminal `{:provider_stream_unsupported, module}` for composed programs without a streamable predictor instead of post-call rechunking. Facade/API/conformance docs and a regression test state the boundary; 106 focused streaming tests pass.

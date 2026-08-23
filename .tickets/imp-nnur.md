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

Provider streaming reaches ordinary composed `Imp.Module` programs, including
selected intermediate predictor fields, without bypassing the program's real
control flow. Final predictions, provider errors, early consumer cancellation,
usage, cache behavior, and predictor identity remain coherent. The stable DSPy
streaming row is not conformant until an executable differential proves that
user capability. Streaming docs state exactly what streams when.


## Notes

**2026-08-21T03:22:15Z**

Chose the allowed loud-fallback disposition. `provider_stream: true` now returns terminal `{:provider_stream_unsupported, module}` for composed programs without a streamable predictor instead of post-call rechunking. Facade/API/conformance docs and a regression test state the boundary; 106 focused streaming tests pass.

**2026-08-22T20:20:00Z**

Reopened after adversarial release review. Loud failure fixed the prior silent
fake-streaming defect, but did not fulfill the stable DSPy user capability:
`dspy.streamify` can observe selected fields from predictors inside a normal
composed module, while Imp still rejects that program before executing it. The
earlier `or fallback is loud+documented` acceptance was a truthfulness stop, not
completion of the intended product. Treat the current behavior as an explicit
gap until the composed path is real.

**2026-08-22T21:03:00Z**

Closed on the real public capability. `Imp.stream/3` now executes the original
program once, resolves ordinary optimizer predictor names, streams raw provider
events or selected `StreamListener` fields as those predictors run, and ends
with the program's typed `Prediction`. The implementation preserves composed
control flow and propagates observation through supervised child tasks without
using it for authority. Demand acknowledgements prevent eager drain; early halt
and consumer death unwind the provider; a sole admitted worker is borrowed
without making arbitrary nested fan-out unbounded. Provider errors appear once,
and ReqLLM terminal metadata records streamed usage once.

The source-bound behavioral port covers two named predictors and proves that
the second prompt receives the first predictor's completed output. Adversarial
tests additionally cover provider failure, early halt, dead consumer, and the
one-worker case. The real OpenRouter path streamed both stages and returned a
valid typed route; the full live gate passed 16/16. Focused runtime tests,
generated conformance, package clean room, the main check, and Dialyzer pass.

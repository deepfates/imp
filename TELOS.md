# DSEx Telos

DSEx is a declarative self-improving programming system for language models
on the BEAM. It stands in the broader DSP tradition while presenting the
user-facing system as ordinary, idiomatic Elixir.

## Definition of Done

- Programs are first-class Elixir values with explicit signatures, configuration, demos, and traces.
- Model, adapter, retriever, and tool boundaries are behaviours or structs that can be swapped in tests.
- Optimizers compile programs from examples and metrics rather than hiding prompt edits in strings.
- End-to-end tests exercise the loop: examples -> optimizer -> program -> LM -> adapter -> prediction -> metric.
- Provider integrations are contract-tested through injectable transports and can be live-tested by supplying credentials.
- Runtime patterns are BEAM-safe by construction: explicit data, OTP boundaries, injectable clients, and supervised state.
- DSEx's public API is exercised by `mix public_surface.check` and the full production gate.
- Production readiness requires `mix production.check` plus the live-provider gate when credentials are present.

## Implemented Surface

- Facade: `DSEx`
- Core: `DSEx`, `DSEx.Settings`, `DSEx.Signature`, `DSEx.Signature.Field`
- Primitives: `DSEx.Example`, `DSEx.Prediction`, `DSEx.Tool`
- Adapters: `DSEx.Adapter.Chat`, `DSEx.Adapter.JSON`, `DSEx.Adapter.XML`, `DSEx.Adapter.TwoStep`, `DSEx.Adapter.BAML`
- Models: `DSEx.LM` behaviour, `DSEx.LM.Fake`, OpenAI/LiteLLM/Local/Databricks OpenAI-compatible clients
- Programs: `DSEx.Predict.Predict`, `DSEx.Predict.ChainOfThought`, `DSEx.Predict.ReAct`, `ProgramOfThought`, `BestOfN`, `Refine`, `Parallel`
- Retrieval and embeddings: `DSEx.Retrieve`, `DSEx.Retrieve.Memory`, `DSEx.Retrievers.KNN`, `DSEx.Embeddings`
- Evaluation: `DSEx.Evaluate`, `DSEx.Metrics`
- Optimizers: `BootstrapFewShot`, `LabeledFewShot`, `RandomSearch`, `COPRO`, `MIPROv2`, `SIMBA`, `GEPA`, `SignatureOptimizer`
- Finetuning: `BootstrapFinetune`, `GRPO`, provider-neutral training jobs and trainer behaviour
- Streaming: enumerable `DSEx.Streaming`
- Datasets: records, JSONL, CSV, GSM8K, and HotPotQA-style loaders
- Persistence: JSON save/load for portable program state
- Sandbox: BEAM-safe arithmetic expression evaluator for program-of-thought
- Adapter types: image, audio, file, document, code, reasoning, history, citation, tool call/result structs

## Completion Boundary

This repo now implements the DSEx programming model end-to-end. The only
boundary not exercised by default is live third-party network behavior: OpenAI,
Databricks, LiteLLM, and local model servers are represented by real HTTP
clients with contract tests against injectable transports. Live calls are an
operational concern requiring credentials and endpoints, not missing library
surface.

Production readiness is defined by [PRODUCTION.md](PRODUCTION.md) and
[PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md), not by manual inspection.

## Test Signals

- Unit tests prove parsing, examples, adapters, and evaluation semantics.
- Integration tests use deterministic fake LMs to verify full program, optimizer, ReAct, RAG, streaming, dataset, sandbox, and finetuning loops.
- Provider tests verify request/response contracts without credentials.

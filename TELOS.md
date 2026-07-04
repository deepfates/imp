# DSPy Elixir Telos

This project translates DSPy philosophically as well as literally.

## Definition of Done

- Programs are first-class Elixir values with explicit signatures, configuration, demos, and traces.
- Model, adapter, retriever, and tool boundaries are behaviours or structs that can be swapped in tests.
- Optimizers compile programs from examples and metrics rather than hiding prompt edits in strings.
- End-to-end tests exercise the loop: examples -> optimizer -> program -> LM -> adapter -> prediction -> metric.
- Provider integrations are contract-tested through injectable transports and can be live-tested by supplying credentials.
- Python-specific runtime patterns are translated into BEAM-safe equivalents rather than copied unsafely.

## Implemented Surface

- Core: `DSPy`, `DSPy.Settings`, `DSPy.Signature`, `DSPy.Signature.Field`
- Primitives: `DSPy.Example`, `DSPy.Prediction`, `DSPy.Tool`
- Adapters: `DSPy.Adapter.Chat`, `DSPy.Adapter.JSON`, `DSPy.Adapter.XML`, `DSPy.Adapter.TwoStep`, `DSPy.Adapter.BAML`
- Models: `DSPy.LM` behaviour, `DSPy.LM.Fake`, OpenAI/LiteLLM/Local/Databricks OpenAI-compatible clients
- Programs: `DSPy.Predict.Predict`, `DSPy.Predict.ChainOfThought`, `DSPy.Predict.ReAct`, `ProgramOfThought`, `BestOfN`, `Refine`, `Parallel`
- Retrieval and embeddings: `DSPy.Retrieve`, `DSPy.Retrieve.Memory`, `DSPy.Retrievers.KNN`, `DSPy.Embeddings`
- Evaluation: `DSPy.Evaluate`, `DSPy.Metrics`
- Optimizers: `BootstrapFewShot`, `LabeledFewShot`, `RandomSearch`, `COPRO`, `MIPROv2`, `SIMBA`, `GEPA`, `SignatureOptimizer`
- Finetuning: `BootstrapFinetune`, `GRPO`, provider-neutral training jobs and trainer behaviour
- Streaming: enumerable `DSPy.Streaming`
- Datasets: records, JSONL, CSV, GSM8K, and HotPotQA-style loaders
- Persistence: JSON save/load for portable program state
- Sandbox: BEAM-safe arithmetic expression evaluator for program-of-thought
- Adapter types: image, audio, file, document, code, reasoning, history, citation, tool call/result structs

## Completion Boundary

This repo now implements the DSPy programming model end-to-end in Elixir. The
only boundary not exercised by default is live third-party network behavior:
OpenAI, Databricks, LiteLLM, and local model servers are represented by real
HTTP clients with contract tests against injectable transports. Live calls are
an operational concern requiring credentials and endpoints, not missing library
surface.

## Test Signals

- Unit tests prove parsing, examples, adapters, and evaluation semantics.
- Integration tests use deterministic fake LMs to verify full program, optimizer, ReAct, RAG, streaming, dataset, sandbox, and finetuning loops.
- Provider tests verify request/response contracts without credentials.

# DSPy Elixir Telos

This project translates DSPy philosophically as well as literally.

## Definition of Done

- Programs are first-class Elixir values with explicit signatures, configuration, demos, and traces.
- Model, adapter, retriever, and tool boundaries are behaviours or structs that can be swapped in tests.
- Optimizers compile programs from examples and metrics rather than hiding prompt edits in strings.
- End-to-end tests exercise the loop: examples -> optimizer -> program -> LM -> adapter -> prediction -> metric.
- The repo records compatibility gaps plainly instead of claiming full Python runtime parity where Elixir should differ.

## Implemented Surface

- Core: `DSPy`, `DSPy.Settings`, `DSPy.Signature`, `DSPy.Signature.Field`
- Primitives: `DSPy.Example`, `DSPy.Prediction`, `DSPy.Tool`
- Adapters: `DSPy.Adapter.Chat`, `DSPy.Adapter.JSON`, `DSPy.Adapter.XML`
- Models: `DSPy.LM` behaviour, `DSPy.LM.Fake`
- Programs: `DSPy.Predict.Predict`, `DSPy.Predict.ChainOfThought`, `DSPy.Predict.ReAct`, `BestOfN`, `Refine`, `Parallel`
- Retrieval: `DSPy.Retrieve`, `DSPy.Retrieve.Memory`, `DSPy.Retrievers.KNN`
- Evaluation: `DSPy.Evaluate`, `DSPy.Metrics`
- Optimizers: `BootstrapFewShot`, `LabeledFewShot`, `RandomSearch`
- Adapter types: image, audio, file, document, code, reasoning, history, citation, tool call/result structs

## Red / Still Open

- Provider clients are not yet implemented for OpenAI, Databricks, LiteLLM, or local servers.
- Finetuning teleprompters (`GRPO`, `BootstrapFinetune`) need provider-backed training jobs.
- Advanced optimizers (`MIPROv2`, `SIMBA`, `GEPA`, `COPRO`) currently need full algorithm ports.
- Python interpreter/program-of-thought features need a BEAM-safe sandbox design.
- Streaming needs a GenStage or Enumerable-based design.
- Dataset loaders should be added as separate optional integrations.

## Test Signals

- Unit tests prove parsing, examples, adapters, and evaluation semantics.
- Integration tests use deterministic fake LMs to verify full program and optimizer loops.
- Future provider tests should be contract tests behind environment variables, never required for local CI.

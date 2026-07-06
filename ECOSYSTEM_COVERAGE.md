# Ecosystem Coverage Comparison

Dachshund brings declarative self-improving language-model programs to idiomatic
Elixir. DSPy, Ax, and optimize_anything/GEPA are useful comparison points
because they share the same philosophy: typed or declarative LM programs,
explicit evaluation, and optimization loops that improve behavior from examples
or feedback.

## Summary

| Capability | Dachshund | Ax | optimize_anything / GEPA |
| --- | --- | --- | --- |
| Declarative signatures | Covered with `Dachshund.Signature`, string signatures, fields, examples, and predictions. | Core feature; signatures compile into prompts, parsers, validators, retries, traces, and optimization inputs. | Not a general signature framework; optimizes text artifacts via evaluator contracts. |
| Structured generation | Covered with Chat/JSON/XML/TwoStep adapters and parser/error tests. | Strong: typed outputs, validation, retries, streaming, and constraints are first-class. | Only through the system being optimized, not as a primary app framework. |
| Providers | Covered for OpenAI-compatible, LiteLLM, Databricks-style, local, training jobs, embeddings, and live smoke. | Broader provider/product matrix: OpenAI, Anthropic, Gemini, gateways, model catalogs, realtime/audio. | Uses engines/reflection LMs to optimize artifacts; provider breadth belongs to its engine layer. |
| Tools and agents | Covered with tools, ReAct/ReActV2, CodeAct, BestOfN, Refine, Parallel, and aggregation. | Stronger product surface: agents, flows, MCP, runtime sessions, skills, memory/context policies. | Can optimize agent architectures, but does not supply a broad agent application framework. |
| Retrieval/RAG | Covered through retriever behavior, in-memory, Weaviate-style, Databricks-style, embeddings. | Covered through functions, MCP/data integrations, agents, and provider ecosystem. | Can optimize RAG prompts/configs if the evaluator exposes traces/diagnostics. |
| Streaming | Covered with provider SSE parsing, program streaming, and stream messages. | Strong: structured streaming is a core generation capability. | Not the central abstraction. |
| Multimodal | Covered for OpenAI-compatible image/audio/file/document encoding and decoding. | Stronger product claim around audio and realtime. | Supports multimodal ASI such as images for optimization feedback. |
| Optimization | Covered with LabeledFewShot, BootstrapFewShot, RandomSearch, MIPROv2, GEPA, SIMBA, COPRO, GRPO, finetune, reports, and behavioral tests. | Stronger current frontier: GEPA/Pareto optimization over prompts, demos, flows, and agents. | Much deeper for reflective text evolution, Pareto search, ASI, and arbitrary text artifacts. |
| Arbitrary text artifact optimization | Minimal first-class experimental API via `Dachshund.Optimize.Anything`; not yet comparable to optimize_anything/GEPA. | Partly through flow/agent/program optimization. | Primary purpose: optimize prompts, code, configs, agent architectures, vector graphics, and more. |
| Multi-language conformance | Elixir only. | Major strength: generated/verified packages for TypeScript plus Python, Java, C++, Go, and Rust. | Python package/API. |
| Production evidence | Strong inside this repo: public surface tests, adversarial audit, deterministic production gate, live provider smoke, behavioral tests. | Public docs describe conformance manifests and generated examples; external comparison would need cloning/running Ax gates. | Public docs and examples emphasize benchmarked case studies; external comparison would need reproducing artifact benchmarks. |

## Where Dachshund Is Competitive

- It is closest to the DSP family in surface area: signatures, adapters, prediction
  modules, retrieval, evaluation, datasets, optimizers, streaming, saving, and
  provider contracts are all represented.
- It has unusually explicit production evidence: P0/P1 audit rows
  map to tests, and `mix production.check` fails if public-surface, audit, or test gates
  regress.
- The BEAM-native choices are credible rather than cosmetic: concurrency uses
  Tasks, persistence avoids secrets, errors are tagged/structured, and provider
  transports are injectable.

## Where Ax Is Ahead

- Ax has a richer productized agent/workflow layer: flows, runtime sessions,
  MCP, skills, memory/context maps, and long-horizon agent affordances.
- Ax has stronger type/schema ergonomics around constraints and validation,
  including fluent schemas and generated native packages.
- Ax's multi-language AxIR/conformance story is a major advantage. Dachshund has
  its own public-surface gate, but it does not yet have a portable IR or
  cross-language conformance fixtures.

## Where optimize_anything / GEPA Is Ahead

- It is much deeper on optimization research: reflective mutation, Pareto
  frontiers, Actionable Side Information, system-aware merge, and optimization
  modes for single-task, multi-task, and generalization.
- It optimizes arbitrary text artifacts, not only LM-program prompts or demos:
  code, configurations, agent architectures, SVGs, policies, and prompts.
- Its evaluator API captures rich diagnostics as the gradient-like signal. This
  Dachshund records traces and optimizer reports, but does not yet expose a general
  "optimize any text artifact" API.

## Best Next Moves

1. Harden `Dachshund.Optimize.Anything` with train/validation splits, richer
   diagnostics, non-append mutations, and comparative benchmark tasks.
2. Extend `Dachshund.Optimizer.GEPA` and `Dachshund.Optimize.GEPA` from deterministic
   mechanics toward
   Pareto-aware candidate pools and ASI-informed mutation.
3. Add transport-backed MCP client/tool discovery support to close the most obvious Ax agent gap.
4. Add schema constraints beyond basic field types: enum, min/max, arrays,
   nested JSON schema, and retry feedback generated from validation errors.
5. Add benchmark fixtures comparing this repo against Ax-style signatures and
   GEPA-style optimize-anything tasks, with reproducible scores in CI.

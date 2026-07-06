# Architecture

The library is organized around a single flow:

```text
Example / inputs
  -> Signature
  -> Program module
  -> Adapter.format/3
  -> LM.generate/2 or stream
  -> Adapter.parse/3
  -> Prediction
  -> Metric / Optimizer / Save / Stream
```

## Public Facade

`Dachshund` in `lib/dachshund.ex` is the canonical public entry point:

- `Dachshund.configure/1`, `Dachshund.context/2`
- `Dachshund.signature/2`, `Dachshund.example/1`, `Dachshund.prediction/1`
- `Dachshund.predict/2`, `chain_of_thought/2`, `react/3`, `react_v2/3`, `rlm/2`
- `Dachshund.call/2`
- provider helpers: `openai/2`, `litellm/2`, `local_lm/2`, `databricks/2`

Use the facade for application code. Use deeper modules when you need direct
control in tests, docs, or advanced systems.

## Core Data

### `Dachshund.Signature`

Defines input and output fields. String field names from external data remain
strings unless the atom already exists, which prevents atom exhaustion.

Important functions:

- `new/2`
- `ensure/1`
- `input_names/1`, `output_names/1`
- `extend/3`, `prepend_output/2`
- `dump/1`, `load/1`
- `json_schema/1`

### `Dachshund.Example`

Stores train/dev/test rows and optional input keys.

Important functions:

- `new/1`
- `with_inputs/2`
- `inputs/1`, `labels/1`
- `get/3`, `fetch!/2`, `put/3`, `delete/2`

### `Dachshund.Prediction`

Stores model outputs plus completions, score, and metadata.

Important functions:

- `new/2`
- `get/3`, `fetch!/2`, `put/3`
- `to_map/1`
- `from_example/2`

## Program Modules

All major program structs implement the `Dachshund.Module` behaviour.

| Module | Purpose |
| --- | --- |
| `Dachshund.Predict.Predict` | Basic signature-to-output LM call. |
| `Dachshund.Predict.ChainOfThought` | Prepends `reasoning` before signature outputs. |
| `Dachshund.Predict.ReAct` | Simple one-shot tool call. |
| `Dachshund.Predict.ReActV2` | Iterative provider-tool-call ReAct with reserved `submit`. |
| `Dachshund.Predict.ProgramOfThought` | LM emits safe arithmetic/code expression, then answer is parsed. |
| `Dachshund.Predict.CodeAct` | CodeAct-style wrapper over the BEAM-safe sandbox. |
| `Dachshund.Predict.RLM` | Recursive language model loop over metadata, sandbox actions, tools, sub-LM calls, and submit. |
| `Dachshund.Predict.MultiChainComparison` | Compares multiple chain-of-thought outputs. |
| `Dachshund.Predict.BestOfN` | Runs a program N times and keeps best by metric. |
| `Dachshund.Predict.Refine` | Repeated attempts with reward threshold. |
| `Dachshund.Predict.Parallel` | Parallel map helpers. |

## Adapters

Adapters implement:

```elixir
format(signature, inputs, opts) :: messages
parse(signature, raw, opts) :: {:ok, prediction} | {:error, reason}
```

Available adapters:

- `Dachshund.Adapter.Chat`
- `Dachshund.Adapter.JSON`
- `Dachshund.Adapter.XML`
- `Dachshund.Adapter.TwoStep`
- `Dachshund.Adapter.BAML`

`JSON` and schema-constrained signatures are the best fit when the output shape
matters more than prose flexibility.

## LMs And Providers

`Dachshund.LM` is a small behaviour. Tests usually use:

```elixir
%{module: Dachshund.LM.Fake, opts: [handler: fn messages, opts -> %{answer: "ok"} end]}
```

Production clients are OpenAI-compatible HTTP wrappers:

- `Dachshund.Clients.OpenAI`
- `Dachshund.Clients.LiteLLM`
- `Dachshund.Clients.Local`
- `Dachshund.Clients.Databricks`

The underlying transport is injectable via `Dachshund.HTTP`, which is how provider
contracts are tested without live credentials.

## Retrieval And Datasets

Retrievers:

- `Dachshund.Retrieve.Memory`
- `Dachshund.Retrievers.KNN`
- `Dachshund.Retrievers.HTTP`
- `Dachshund.Retrievers.Weaviate`
- `Dachshund.Retrievers.Databricks`

Datasets:

- `Dachshund.Datasets.from_records/3`
- `jsonl/3`, `csv/3`
- `GSM8K`, `HotPotQA`, `MATH`, `Colors`
- `Dachshund.Datasets.Dataset` split container

## Evaluation

`Dachshund.Evaluate` runs a program over a dev set with a metric.

Built-in metrics live in `Dachshund.Metrics`:

- exact match
- semantic-ish F1 helpers
- custom functions of arity 2 or 3

## Optimization

Metric-driven optimizers live under `Dachshund.Optimizer.*`:

- `LabeledFewShot`
- `BootstrapFewShot`
- `RandomSearch`
- `InstructionSearch`
- `COPRO`
- `MIPROv2`
- `SIMBA`
- `GEPA`
- `BetterTogether`
- `BootstrapFinetune`, `GRPO`

V2 arbitrary artifact optimization lives under `Dachshund.Optimize.*`:

- `Dachshund.Optimize.Anything`
- `Dachshund.Optimize.GEPA`

## Agents, Tools, MCP

`Dachshund.Tool` wraps callable functionality. `Dachshund.Agent` composes tools, child
agents, memory/context, policies, and traces.

`Dachshund.MCP` imports in-process or HTTP-discovered tool catalogs into `Dachshund.Tool`
values. The HTTP client supports deterministic transport-backed tests and
remote `tools/list` / `tools/call` style flows.

## RLM

`Dachshund.Predict.RLM` is intentionally not RAG. It gives the controller LM:

- signature metadata
- variable metadata and previews
- observations
- tools
- remaining budget

The controller may return actions:

- `eval`
- `assign`
- `tool`
- `llm_query`
- `submit`

The implementation uses the BEAM-safe sandbox instead of arbitrary Python/Deno
execution. That is a deliberate production translation.

## Persistence

`Dachshund.Saving` saves portable program state. It does not persist secrets. Loading
an HTTP LM requires explicit credential rebinding rather than silently capturing
ambient environment credentials.

## Gates

The production and V2 gates are not docs-only promises:

- `mix production.check`
- `mix v2.check`
- `LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs`

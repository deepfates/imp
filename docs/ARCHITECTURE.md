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

`DSPy` in `lib/dspy.ex` is the friendly entry point:

- `DSPy.configure/1`, `DSPy.context/2`
- `DSPy.signature/2`, `DSPy.example/1`, `DSPy.prediction/1`
- `DSPy.predict/2`, `chain_of_thought/2`, `react/3`, `react_v2/3`, `rlm/2`
- provider helpers: `openai/2`, `litellm/2`, `local_lm/2`, `databricks/2`

Use the facade for application code. Use deeper modules when you need direct
control in tests, docs, or advanced systems.

## Core Data

### `DSPy.Signature`

Defines input and output fields. String field names from external data remain
strings unless the atom already exists, which prevents atom exhaustion.

Important functions:

- `new/2`
- `ensure/1`
- `input_names/1`, `output_names/1`
- `extend/3`, `prepend_output/2`
- `dump/1`, `load/1`
- `json_schema/1`

### `DSPy.Example`

Stores train/dev/test rows and optional input keys.

Important functions:

- `new/1`
- `with_inputs/2`
- `inputs/1`, `labels/1`
- `get/3`, `fetch!/2`, `put/3`, `delete/2`

### `DSPy.Prediction`

Stores model outputs plus completions, score, and metadata.

Important functions:

- `new/2`
- `get/3`, `fetch!/2`, `put/3`
- `to_map/1`
- `from_example/2`

## Program Modules

All major program structs implement the `DSPy.Module` behaviour.

| Module | Purpose |
| --- | --- |
| `DSPy.Predict.Predict` | Basic signature-to-output LM call. |
| `DSPy.Predict.ChainOfThought` | Prepends `reasoning` before signature outputs. |
| `DSPy.Predict.ReAct` | Simple one-shot tool call. |
| `DSPy.Predict.ReActV2` | Iterative provider-tool-call ReAct with reserved `submit`. |
| `DSPy.Predict.ProgramOfThought` | LM emits safe arithmetic/code expression, then answer is parsed. |
| `DSPy.Predict.CodeAct` | CodeAct-style wrapper over the BEAM-safe sandbox. |
| `DSPy.Predict.RLM` | Recursive language model loop over metadata, sandbox actions, tools, sub-LM calls, and submit. |
| `DSPy.Predict.MultiChainComparison` | Compares multiple chain-of-thought outputs. |
| `DSPy.Predict.BestOfN` | Runs a program N times and keeps best by metric. |
| `DSPy.Predict.Refine` | Repeated attempts with reward threshold. |
| `DSPy.Predict.Parallel` | Parallel map helpers. |

## Adapters

Adapters implement:

```elixir
format(signature, inputs, opts) :: messages
parse(signature, raw, opts) :: {:ok, prediction} | {:error, reason}
```

Available adapters:

- `DSPy.Adapter.Chat`
- `DSPy.Adapter.JSON`
- `DSPy.Adapter.XML`
- `DSPy.Adapter.TwoStep`
- `DSPy.Adapter.BAML`

`JSON` and schema-constrained signatures are the best fit when the output shape
matters more than prose flexibility.

## LMs And Providers

`DSPy.LM` is a small behaviour. Tests usually use:

```elixir
%{module: DSPy.LM.Fake, opts: [handler: fn messages, opts -> %{answer: "ok"} end]}
```

Production clients are OpenAI-compatible HTTP wrappers:

- `DSPy.Clients.OpenAI`
- `DSPy.Clients.LiteLLM`
- `DSPy.Clients.Local`
- `DSPy.Clients.Databricks`

The underlying transport is injectable via `DSPy.HTTP`, which is how provider
contracts are tested without live credentials.

## Retrieval And Datasets

Retrievers:

- `DSPy.Retrieve.Memory`
- `DSPy.Retrievers.KNN`
- `DSPy.Retrievers.HTTP`
- `DSPy.Retrievers.Weaviate`
- `DSPy.Retrievers.Databricks`

Datasets:

- `DSPy.Datasets.from_records/3`
- `jsonl/3`, `csv/3`
- `GSM8K`, `HotPotQA`, `MATH`, `Colors`
- `DSPy.Datasets.Dataset` split container

## Evaluation

`DSPy.Evaluate` runs a program over a dev set with a metric.

Built-in metrics live in `DSPy.Metrics`:

- exact match
- semantic-ish F1 helpers
- custom functions of arity 2 or 3

## Optimization

Classic teleprompter-style optimizers live under `DSPy.Teleprompt.*`:

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

V2 arbitrary artifact optimization lives under `DSPy.Optimize.*`:

- `DSPy.Optimize.Anything`
- `DSPy.Optimize.GEPA`

## Agents, Tools, MCP

`DSPy.Tool` wraps callable functionality. `DSPy.Agent` composes tools, child
agents, memory/context, policies, and traces.

`DSPy.MCP` imports in-process or HTTP-discovered tool catalogs into `DSPy.Tool`
values. The HTTP client supports deterministic transport-backed tests and
remote `tools/list` / `tools/call` style flows.

## RLM

`DSPy.Predict.RLM` is intentionally not RAG. It gives the controller LM:

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

`DSPy.Saving` saves portable program state. It does not persist secrets. Loading
an HTTP LM requires explicit credential rebinding rather than silently capturing
ambient environment credentials.

## Gates

The production and V2 gates are not docs-only promises:

- `mix production.check`
- `mix v2.check`
- `LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs`

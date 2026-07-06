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

`DSEx` in `lib/dsex.ex` is the canonical public entry point:

- `DSEx.configure/1`, `DSEx.context/2`
- `DSEx.signature/2`, `DSEx.example/1`, `DSEx.prediction/1`
- `DSEx.predict/2`, `chain_of_thought/2`, `react/3`, `react_v2/3`, `rlm/2`
- `DSEx.call/2`
- provider helpers: `openai/2`, `litellm/2`, `local_lm/2`, `databricks/2`

Use the facade for application code. Use deeper modules when you need direct
control in tests, docs, or advanced systems.

## Core Data

### `DSEx.Signature`

Defines input and output fields. The string DSL supports typed flat fields,
descriptions, arrays, and enum/class constraints with position-aware parse
errors. String field names from external data remain strings unless the atom
already exists, which prevents atom exhaustion.

Important functions:

- `new/2`
- `ensure/1`
- `input_names/1`, `output_names/1`
- `extend/3`, `prepend_output/2`
- `dump/1`, `load/1`
- `json_schema/1`

### `DSEx.Example`

Stores train/dev/test rows and optional input keys.

Important functions:

- `new/1`
- `with_inputs/2`
- `inputs/1`, `labels/1`
- `get/3`, `fetch!/2`, `put/3`, `delete/2`

### `DSEx.Prediction`

Stores model outputs plus completions, score, and metadata.

Important functions:

- `new/2`
- `get/3`, `fetch!/2`, `put/3`
- `to_map/1`
- `from_example/2`

## Program Modules

All major program structs implement the `DSEx.Module` behaviour.

| Module | Purpose |
| --- | --- |
| `DSEx.Predict.Predict` | Basic signature-to-output LM call. |
| `DSEx.Predict.ChainOfThought` | Prepends `reasoning` before signature outputs. |
| `DSEx.Predict.ReAct` | Compatibility facade for `ReActV2`. |
| `DSEx.Predict.ReActV2` | Canonical iterative provider-tool-call ReAct with reserved `submit`. |
| `DSEx.Predict.ProgramOfThought` | LM emits a safe expression or tool action plan. |
| `DSEx.Predict.CodeAct` | Iterates tool observations and BEAM-safe sandbox execution with trace metadata. |
| `DSEx.Predict.RLM` | Recursive language model loop over metadata, sandbox actions, tools, sub-LM calls, and submit. |
| `DSEx.Predict.MultiChainComparison` | Compares multiple chain-of-thought outputs. |
| `DSEx.Predict.BestOfN` | Runs a program N times and keeps best by metric. |
| `DSEx.Predict.Refine` | Repeated attempts with reward threshold. |
| `DSEx.Predict.Parallel` | Parallel map helpers. |

## Adapters

Adapters implement:

```elixir
format(signature, inputs, opts) :: messages
parse(signature, raw, opts) :: {:ok, prediction} | {:error, reason}
```

Available adapters:

- `DSEx.Adapter.Chat`
- `DSEx.Adapter.JSON`
- `DSEx.Adapter.XML`
- `DSEx.Adapter.TwoStep`
- `DSEx.Adapter.BAML`

`JSON` and schema-constrained signatures are the best fit when the output shape
matters more than prose flexibility.

## LMs And Providers

`DSEx.LM` is a small behaviour. Tests usually use:

```elixir
%{module: DSEx.LM.Fake, opts: [handler: fn messages, opts -> %{answer: "ok"} end]}
```

Production clients are OpenAI-compatible HTTP wrappers:

- `DSEx.Clients.OpenAI`
- `DSEx.Clients.LiteLLM`
- `DSEx.Clients.Local`
- `DSEx.Clients.Databricks`

The underlying transport is injectable via `DSEx.HTTP`, which is how provider
contracts are tested without live credentials.

Provider clients use real transport by default. Deterministic provider-contract
tests must opt into `DSEX_TEST_MODE=mock`, `DSEX_TEST_MODE=fallback`, or a
constructor-level `test_mode:`.

Provider streaming is transport-dependent. Transports that implement
`DSEx.HTTP.stream/4` can deliver incremental chunks. Transports that only
implement `post/4`, including the default `:httpc` transport, expose a buffered
body that DSEx can parse as stream events but cannot make incrementally arrive.

Runtime dependencies are deliberately small and production-oriented:

- `Jason` is the JSON boundary for providers, adapters, datasets, reports, and
  saved state.
- `NimbleOptions` validates network-facing and provider-facing constructor
  options so typos fail before a live request or training job is submitted.
- `:telemetry` is the stable observability boundary. DSEx keeps a tiny wrapper
  in `DSEx.Telemetry` so tests can also attach process-local handlers.
- `ExDoc` is dev/test only and is part of the production gate because generated
  docs are treated as release artifacts.

Runtime boundaries emit redacted telemetry events for LM calls, streaming
chunks, adapter parse retries/failures, cache hits/misses, tool calls,
retrievers, MCP requests, training jobs, and optimizer trials.

## Retrieval And Datasets

Retrievers:

- `DSEx.Retrieve.Memory`
- `DSEx.Retrievers.KNN`
- `DSEx.Retrievers.HTTP`
- `DSEx.Retrievers.Weaviate`
- `DSEx.Retrievers.Databricks`

Datasets:

- `DSEx.Datasets.from_records/3`
- `jsonl/3`, `csv/3`
- `GSM8K`, `HotPotQA`, `MATH`, `Colors`
- `DSEx.Datasets.Dataset` split container

## Evaluation

`DSEx.Evaluate` runs a program over a dev set with a metric.

Built-in metrics live in `DSEx.Metrics`:

- exact match
- semantic-ish F1 helpers

Metric returns are normalized by `DSEx.Metrics.normalize_result/1`. Metrics may
return booleans, numbers, maps with score/feedback, or predictions. Evaluation
rows preserve normalized score, pass/fail state, feedback, metric metadata, and
program errors. Arity-3 metrics receive the prediction trace as their third
argument.
- custom functions of arity 2 or 3

## Optimization

Metric-driven optimizers live under `DSEx.Optimizer.*`:

- `LabeledFewShot`
- `BootstrapFewShot`
- `RandomSearch`
- `InstructionSearch`
- `COPRO`
- `MIPROv2`
- `SIMBA`
- `GEPA`
- `BetterTogether`
- `BootstrapFinetune`, `GRPO` build provider training jobs only when an
  explicit real trainer backend is supplied. DSEx does not include an in-process
  local training fallback.

V2 arbitrary artifact optimization lives under `DSEx.Optimize.*`:

- `DSEx.Optimize.Anything`
- `DSEx.Optimize.GEPA`

## Agents, Tools, MCP

`DSEx.Tool` wraps callable functionality. `DSEx.Agent` composes tools, child
agents, memory/context, policies, and traces.

`DSEx.MCP` imports in-process, HTTP, stdio, or Streamable HTTP tool catalogs
into `DSEx.Tool` values. Transport clients use JSON-RPC 2.0 envelopes,
initialize before discovery, and expose remote `tools/list` / `tools/call`
style flows through ordinary tools. Stdio clients spawn trusted local MCP
server executables; they are not a sandbox for untrusted commands.

## RLM

`DSEx.Predict.RLM` is intentionally not RAG. It gives the controller LM:

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
- `recurse`
- `submit`

The implementation uses a BEAM-safe sandbox for production control.

## Persistence

`DSEx.Saving` saves portable program state. It does not persist secrets. Loading
an HTTP LM requires explicit credential rebinding rather than silently capturing
ambient environment credentials.

## Gates

The production and V2 gates are not docs-only promises:

- `mix production.check`
- `mix v2.check`
- `mix integration.check`
- `LIVE_PROVIDER=1 mix live.check`

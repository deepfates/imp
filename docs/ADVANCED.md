# Advanced DSEx

This guide covers DSEx's advanced program-building tools: arbitrary artifact
optimization, Pareto-guided reflection, agent runtimes, MCP-style tool
catalogs, schema constraints, and deterministic benchmark fixtures.

## Gates

Advanced DSEx behavior is part of the source-checkout production gate. These
commands must pass before release:

```sh
mix production.check
mix integration.check
LIVE_PROVIDER=1 mix live.check
```

`mix production.check` enforces warnings-as-errors compilation, formatting,
documentation generation, public surface checks, and deterministic benchmark
tests. The benchmark suite includes positive controls that must reach threshold
and negative controls that must remain below threshold.

## Optimize Anything

```elixir
alias DSEx.Optimize.Anything
alias DSEx.Optimize.Anything.{Config, Result}

config =
  Config.new(
    engine: [max_candidate_proposals: 2, run_dir: "tmp/anything-run"],
    reflection: [module_selector: :all]
  )

result =
  Anything.optimize(
    %{config: "mode=slow", policy: "prefer safe changes"},
    fn candidate ->
      if candidate.config == "mode=fast", do: 1.0, else: 0.0
    end,
    config: config,
    fallback_proposer: fn candidate, component, _feedback, _iteration ->
      case component do
        :config -> "mode=fast"
        :policy -> candidate.policy
      end
    end
  )

Result.best_candidate(result)
#=> %{config: "mode=fast", policy: "prefer safe changes"}
```

The public frontend delegates to the production GEPA engine. With no dataset,
an arity-one evaluator selects single-task mode. `dataset:` selects multi-task
mode with an arity-two evaluator, and `dataset:` plus `valset:` evaluates held-
out generalization. A `nil` seed requires `objective:` and a configured
`reflection_lm`; a binary seed is exposed to the engine as one named component.

Evaluators may return a numeric score or `{score, side_information}`. Side
information can contain component-specific feedback, objective subscores, and
typed images. Config controls candidate and module selection, refinement,
perfect-score skipping, merge, stopping, metric/reflection budgets, bounded
concurrency, and callbacks. Custom selectors implement the documented GEPA
selector behaviours rather than being special-cased in the runner.

When `run_dir` is set, DSEx writes atomic JSON checkpoints and seed/best
validation outputs. Evaluation caching defaults to durable, content-addressed
JSON storage for run directories and fails closed on corrupt or incompatible
entries. Without a run directory, enabled caching is in-memory. Persisted
config and results use tagged JSON codecs; W&B credentials are never written.

External tracking is optional:

```elixir
Config.new(
  engine: [max_candidate_proposals: 10, run_dir: "tmp/anything-run"],
  tracking: [
    use_wandb: true,
    wandb_init_kwargs: %{project: "artifact-optimization"},
    use_mlflow: true,
    mlflow_tracking_uri: "http://127.0.0.1:5000",
    mlflow_experiment_name: "artifact-optimization"
  ]
)
```

W&B reads `WANDB_API_KEY` unless `wandb_api_key` is supplied at runtime.
MLflow supports `MLFLOW_TRACKING_TOKEN` or the standard username/password
environment variables. Backend startup failures abort the run; later logging
or finish failures are warnings. DSEx reports accurate failed terminal status,
while the isolated W&B client can reproduce GEPA v0.1.1's success-only finish
behavior when explicitly configured for compatibility.

The source-checkout effectiveness lane uses executable code, agent
configuration, and scheduling artifacts:

```sh
mix benchmark.optimize_anything.check
mix dsex.benchmark.optimize_anything --live --provider openai \
  --model gpt-5.4-2026-03-05 --seeds 17,23,31 --max-proposals 5 \
  --out benchmarks/results
```

The smoke command validates wiring only. The source-checkout benchmark guide
defines the multi-seed, held-out evaluation, cost, and checkpoint requirements
that authorize the scoped live effectiveness claim.

The compatibility `Artifact`/`Report` API remains available and delegates to
the same engine. New code should use binary or named-map candidates and the
production `Result` contract above.

Release fidelity is pinned to GEPA v0.1.1. Adapter-owned resume, reflection
budgets, attachable tracking runs, and other selected post-tag lifecycle fixes
are DSEx production extensions, not a claim of parity with unreleased GEPA
main. Real non-prompt effectiveness campaigns remain a separate release gate.

## Pareto/ASI GEPA-Style Reflection

`DSEx.Optimize.GEPA` is a DSEx-native artifact optimizer. It uses the GEPA
philosophy of per-example scores, Actionable Side Information, Pareto frontier
selection, and reflective mutation, but it is not a Python GEPA wrapper and does
not imply paper-scale benchmark results without the separate parity evidence
gates.

```elixir
artifact = DSEx.Optimize.Anything.new_artifact(:prompt, "Base")

report =
  DSEx.Optimize.GEPA.optimize(
    artifact,
    fn artifact, examples ->
      %{
        per_example_scores:
          Enum.map(examples, &if(String.contains?(artifact.text, &1), do: 1.0, else: 0.0)),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end,
    examples: ["Paris", "concise"],
    generations: 2,
    mutation_fn: fn _artifact, asi, _generation -> Enum.join(asi, "\n") end
  )

report.best.aggregate_score
#=> 1.0
```

The report tracks per-example scores, Pareto frontier membership, ASI
diagnostics, candidate lineage, replacement branches, and system-aware merges.

## Agents And MCP

```elixir
tool = DSEx.tool(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

agent =
  DSEx.Agent.new(:doubler, fn agent, %{x: x}, runtime ->
    DSEx.Agent.call_tool(agent, :double, %{x: x}, runtime)
  end, tools: [tool])

{:ok, %{y: 8}, runtime} = DSEx.Agent.run(agent, %{x: 4})
runtime.traces
```

MCP-style catalogs import external schemas into ordinary `DSEx.Tool` structs:

```elixir
catalog =
  DSEx.MCP.Catalog.new([
    %{name: :lookup, description: "lookup", input_schema: %{required: [:key]}, run: & &1}
  ])

[tool] = DSEx.MCP.import_tools(catalog)
```

Runtime sessions support memory, large context references, tool failures, child
agents, tool policies, final-output streams, incremental trace-event streams,
and trace capture.

## Protocol Clients

The normal provider path for LM inference is still `DSEx.req_llm/2`. Use the
protocol clients below only when your application owns the external service
boundary directly.

HTTP retrievers wrap search services behind the shared `DSEx.Retrieve`
behaviour:

```elixir
retriever =
  DSEx.Retrievers.HTTP.new("https://retriever.example/search",
    body_builder: fn query, opts -> %{query: query, k: Keyword.get(opts, :k, 3)} end,
    response_mapper: fn _retriever, decoded -> decoded["documents"] end
  )
```

Provider-shaped retriever constructors build payload-compatible clients for
specific APIs while keeping credentials explicit:

```elixir
weaviate = DSEx.Retrievers.Weaviate.new("https://weaviate.example", "Passage")

databricks =
  DSEx.Retrievers.Databricks.new(
    "https://workspace.example",
    "catalog.schema.index",
    token: System.fetch_env!("DATABRICKS_TOKEN")
)
```

Network-facing protocol clients share the same transport boundary: `transport:`
accepts an HTTP transport module or an arity-4 callback with
`(url, headers, body, opts)`. Malformed transport shapes are rejected when the
client is built, before an MCP, retriever, or provider-training call can reach
the network.

Provider training is also explicit. `BootstrapFinetune` and `GRPO` build
provider training jobs only when a real trainer backend is supplied; they do not
train models in-process and do not pretend to have a local training backend.
Trainer options accept `nil`, a trainer module, a configured trainer struct, or
an arity-3 callback so tests and applications can inject the training boundary
without ambient provider state.

```elixir
trainer = DSEx.Clients.OpenAITrainer.new(training_file: "file-provider-id")
```

`OpenAITrainer` and `DatabricksTrainer` return configured
`%DSEx.Clients.HTTPTrainer{}` values. Pattern match on `provider: :openai` or
`provider: :databricks` when you need to inspect the returned trainer. The
OpenAI trainer submits a fine-tuning job for an already uploaded provider file;
it does not upload examples itself.

## Schema Constraints

```elixir
signature =
  DSEx.signature(%{
    inputs: [:question],
    outputs: [
      %{name: :answer, type: :string, constraints: %{enum: ["yes", "no"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })

DSEx.Signature.json_schema(signature)
```

Supported constraints include enum, numeric bounds, string length, regex
patterns, arrays, nested objects, and optional fields. JSON adapter parse errors
return retry feedback suitable for another model attempt.

## Release Evidence

DSEx keeps release evidence behind Mix gates rather than presenting benchmark
helpers as application APIs. In a source checkout:

```sh
mix production.check
# source checkout only
mix evidence.check
```

The deterministic evidence fixtures cover:

- Ax-style structured extraction with schema constraints.
- Agent/tool execution with trace evidence.
- GEPA prompt optimization.
- Program optimization with a reward fixture where the baseline fails and the
  compiled program passes.
- Arbitrary config optimization.

## Production Boundaries

Advanced DSEx APIs are part of the same release contract as the core facade:
they must pass deterministic tests, compile with warnings as errors, preserve
JSON-safe persistence where applicable, and keep provider credentials out of
saved artifacts.

MCP support covers catalog import plus JSON-RPC HTTP, stdio, and Streamable HTTP
clients. The benchmark fixtures are deterministic regression fixtures for
DSEx behavior, not public leaderboard claims. Provider-native schema APIs and
streaming are explicit provider responsibilities layered over the shared DSEx
contracts and tested through injectable transports.

For real dataset benchmark evidence, use the maintainer evidence notes in the
source repository. That lane fetches canonical GSM8K/HotPotQA rows, writes
manifests and result artifacts, and keeps research evidence separate from the
normal product gate.

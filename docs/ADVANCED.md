# Advanced Imp

This guide covers Imp's advanced program-building tools: arbitrary artifact
optimization, Pareto-guided reflection, agent runtimes, MCP-style tool
catalogs, schema constraints, and deterministic benchmark fixtures.

## Gates

Advanced Imp behavior is part of the source-checkout production gate. These
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
alias Imp.Optimize.Anything
alias Imp.Optimize.Anything.{Config, Result}

config =
  Config.new(
    engine: [max_candidate_proposals: 2, run_dir: "tmp/anything-run"],
    reflection: [module_selector: :all]
  )

result =
  Anything.run(
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

When `run_dir` is set, Imp writes atomic JSON checkpoints and seed/best
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
or finish failures are warnings. Imp reports accurate failed terminal status,
while the isolated W&B client can reproduce GEPA v0.1.1's success-only finish
behavior when explicitly configured for compatibility.

The source-checkout effectiveness lane uses executable code, agent
configuration, and scheduling artifacts:

```sh
mix benchmark.optimize_anything.check
mix imp.benchmark.optimize_anything --live --provider openai \
  --model gpt-5.4-2026-03-05 --seeds 17,23,31 --max-proposals 5 \
  --out benchmarks/results
```

The smoke command validates wiring only. The source-checkout benchmark guide
defines the multi-seed, held-out evaluation, cost, and checkpoint requirements
that authorize the scoped live effectiveness claim.

Release fidelity is pinned to GEPA v0.1.1. Adapter-owned resume, reflection
budgets, attachable tracking runs, and other selected post-tag lifecycle fixes
are Imp production extensions, not a claim of parity with unreleased GEPA
main. Real non-prompt effectiveness campaigns remain a separate release gate.

## Agents And MCP

```elixir
tool = Imp.tool(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

agent =
  Imp.Agent.new(:doubler, fn agent, %{x: x}, runtime ->
    Imp.Agent.call_tool(agent, :double, %{x: x}, runtime)
  end, tools: [tool])

{:ok, %{y: 8}, runtime} = Imp.Agent.run(agent, %{x: 4})
runtime.traces
```

MCP-style catalogs import external schemas into ordinary `Imp.Tool` structs:

```elixir
catalog =
  Imp.MCP.Catalog.new([
    %{name: :lookup, description: "lookup", input_schema: %{required: [:key]}, run: & &1}
  ])

[tool] = Imp.MCP.import_tools(catalog)
```

Runtime sessions support memory, large context references, tool failures, child
agents, tool policies, final-output streams, incremental trace-event streams,
and trace capture.

## Protocol Clients

The normal provider path for LM inference is still `Imp.req_llm/2`. Use the
protocol clients below only when your application owns the external service
boundary directly.

HTTP retrievers wrap search services behind the shared `Imp.Retrieve`
behaviour:

```elixir
retriever =
  Imp.Retrievers.HTTP.new("https://retriever.example/search",
    body_builder: fn query, opts -> %{query: query, k: Keyword.get(opts, :k, 3)} end,
    response_mapper: fn _retriever, decoded -> decoded["documents"] end
  )
```

Provider-shaped retriever constructors build payload-compatible clients for
specific APIs while keeping credentials explicit:

```elixir
weaviate = Imp.Retrievers.Weaviate.new("https://weaviate.example", "Passage")

databricks =
  Imp.Retrievers.Databricks.new(
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
training jobs only when a real trainer backend is supplied; they
do not train models in-process.
Trainer options accept `nil`, a trainer module, a configured trainer struct, or
an arity-3 callback so tests and applications can inject the training boundary
without ambient provider state.

```elixir
trainer = Imp.Clients.OpenAITrainer.new(training_file: "file-provider-id")
```

`OpenAITrainer` and `DatabricksTrainer` return configured
`%Imp.Clients.HTTPTrainer{}` values. Pattern match on `provider: :openai` or
`provider: :databricks` when you need to inspect the returned trainer. The
OpenAI trainer submits a fine-tuning job for an already uploaded provider file;
it does not upload examples itself.

### Optional local MLX-LM SFT

Apple Silicon hosts can install the separately versioned trainer executable:

```bash
uv tool install 'mlx-lm[train]==0.31.3'
```

`Imp.Clients.MLXLMTrainer` accepts only a local Hugging Face snapshot whose
directory name is the exact configured revision. The successful proof used this
pinned model artifact; do not replace its revision with `main`:

| Model artifact | Revision |
| --- | --- |
| `mlx-community/Qwen2.5-0.5B-Instruct-4bit` | `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3` |

Download a snapshot into the normal Hugging Face cache before training, then
pass the signature and actual Imp adapter used by the program:

```bash
hf download mlx-community/Qwen2.5-0.5B-Instruct-4bit \
  --revision a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3
```

```elixir
trainer =
  Imp.Clients.MLXLMTrainer.new(
    signature: Imp.signature("question -> answer"),
    adapter: Imp.Adapter.Chat,
    stratify_by: [:route],
    executable: "uvx",
    executable_args: ["--from", "mlx-lm==0.31.3", "mlx_lm.lora"]
  )

{:ok, job} = Imp.Clients.Trainer.finetune(trainer, deployment_lm, examples)
```

The proven 80-example configuration produced 72 training and 8 validation rows
stratified by `route`, with prompt masking, 8 LoRA layers, batch size 1,
gradient accumulation 4, 216 iterations, learning rate `1.0e-4`, maximum
sequence length 512, and seed 0. These are the trainer defaults except
`stratify_by`, which remains generic and must be set to `[:route]` by this
campaign. MLX-LM receives gradient accumulation through its pinned 0.31.3
`--grad-accumulation-steps` option.

The model snapshot used for training and the returned adapter directory are
separate artifacts. This backend produces and verifies the adapter only; it
does not fuse or deploy it. The synchronous callback reports success only after
the adapter config and weights have been hashed into a durable,
content-addressed manifest. The executable is invoked directly with an argument
vector, never through a shell. `executable_args` supports a pinned launcher such
as `uvx`; these prefix arguments participate in that direct invocation.

#### External process dependency decision

Imp intentionally does not add MuonTrap or Rambo for this backend. The review
was against MuonTrap `1.8.0` and Rambo `0.3.4`, not their names or README claims:

| Candidate | Decision | Blocking gap |
| --- | --- | --- |
| [MuonTrap 1.8.0](https://github.com/fhunleth/muontrap/tree/v1.8.0) | Do not buy for MLX-LM | Its non-cgroup path escalates TERM to KILL for the immediate child; complete descendant cleanup is implemented only through Linux cgroups, which does not cover Apple Silicon/macOS training hosts. |
| [Rambo 0.3.4](https://github.com/jayjun/rambo/tree/0.3.4) | Do not buy for MLX-LM | Timeout closes its shim and Rust `kill_on_drop(true)` targets the direct child; captured stdout/stderr are accumulated without a byte bound and there is no TERM grace period. |

`Imp.ExternalCommand` therefore follows the repository's exercised
`ParitySidecar` precedent: direct executable plus argv, one Port-owned OS process
group, checked group TERM/KILL, caller-death cleanup, and bounded tail capture.
This is a deliberate narrow wrapper, not a general process-management library.

Long-running local servers use the managed form. `stop/2` returns only after the
Port has exited and the OS process group is absent; caller death remains a
fallback rather than the normal shutdown protocol:

```elixir
{:ok, handle} =
  Imp.ExternalCommand.start("uvx", server_argv,
    timeout: :infinity,
    kill_grace_ms: 2_000
  )

try do
  evaluate_local_model()
after
  :ok = Imp.ExternalCommand.stop(handle, 10_000)
end
```

Run the source-checkout campaign with:

```sh
mix imp.benchmark.local_mlx
```

The campaign owns the complete local effectiveness proof: immutable dataset and model-tree validation, matched
base/adapter/fused evaluation, adapter replay verification, fusion, explicit
deployment-LM rebinding, checksummed save/load, synchronous server cleanup, and
a verified run envelope. It requires a clean checkout by default and writes a
new immutable evidence file rather than overwriting prior results. This evidence
supports a local weight-training effectiveness claim; it does not by itself
establish BetterTogether parity.

The canonical post-hardening campaign at commit `922a85e` improved held-out Banking77
accuracy from `0.15` to `0.85` and macro-F1 from `0.0769` to `0.8430` across 40
rows. The fused and save/load-rebound programs produced identical row outcomes.
`LocalMLXCampaign.validate_artifact/1` independently verifies the checked-in
artifact before the dashboard admits this narrow claim.

MLX-LM `0.31.3` does not admit an adapter-served equivalence claim: its server
remaps `default_model` before consulting the CLI adapter map, so
`--adapter-path` is not applied to that request. The campaign therefore uses the
pinned official `mlx_lm.fuse` command as the adapter-to-deployment bridge and
records adapter hashes, fusion argv, output, and the complete fused tree. It
does not report the server's base-model output as adapter inference.

## Schema Constraints

```elixir
signature =
  Imp.signature(%{
    inputs: [:question],
    outputs: [
      %{name: :answer, type: :string, constraints: %{enum: ["yes", "no"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })

Imp.Signature.json_schema(signature)
```

Supported constraints include enum, numeric bounds, string length, regex
patterns, arrays, nested objects, and optional fields. JSON adapter parse errors
return retry feedback suitable for another model attempt.

## Release Evidence

Imp keeps release evidence behind Mix gates rather than presenting benchmark
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

Advanced Imp APIs are part of the same release contract as the core facade:
they must pass deterministic tests, compile with warnings as errors, preserve
JSON-safe persistence where applicable, and keep provider credentials out of
saved artifacts.

MCP support covers catalog import plus JSON-RPC HTTP, stdio, and Streamable HTTP
clients. The benchmark fixtures are deterministic regression fixtures for
Imp behavior, not public leaderboard claims. Provider-native schema APIs and
streaming are explicit provider responsibilities layered over the shared Imp
contracts and tested through injectable transports.

For real dataset benchmark evidence, use the maintainer evidence notes in the
source repository. That lane fetches canonical GSM8K/HotPotQA rows, writes
manifests and result artifacts, and keeps research evidence separate from the
normal product gate.

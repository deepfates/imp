# Advanced Imp

This guide covers Imp's advanced program-building tools: arbitrary artifact
optimization, Pareto-guided reflection, agent runtimes, MCP-style tool
catalogs, schema constraints, and deterministic regression coverage.

## Optimize Anything

```elixir
result =
  Imp.Optimize.Anything.run(
    %{
      enabled: false,
      retries: 1,
      policy: %{route: "safe", weights: [1.0, 0.0]}
    },
    fn candidate ->
      if candidate.enabled and candidate.policy.route == "fast", do: 1.0, else: 0.0
    end,
    config: [
      engine: [max_candidate_proposals: 3, run_dir: "tmp/anything-run"],
      reflection: [module_selector: :all]
    ],
    fallback_proposer: fn _candidate, component, _feedback, _iteration ->
      case component do
        :enabled -> true
        :retries -> 3
        :policy -> %{route: "fast", weights: [0.25, 0.75]}
      end
    end
  )

result
#=> an immutable Optimize Anything result containing the winning candidate
```

The public frontend delegates to the production GEPA engine. With no dataset,
an arity-one evaluator selects single-task mode. `dataset:` selects multi-task
mode with an arity-two evaluator, and `dataset:` plus `valset:` evaluates held-
out generalization. A `nil` seed requires `objective:` and a configured
`reflection_lm`; a binary seed is exposed to the engine as one named component.

Named text maps follow pinned GEPA v0.1.4's `dict[str, str]` contract. A map
containing non-text values selects Imp's native structured mode: the evaluator,
custom proposer, trajectories, and result all receive the native JSON-safe
artifact, while an internal tagged representation lets the shared GEPA engine
hash and checkpoint it. The seed fixes exact map keys, list lengths, and value
types; malformed, partial, type-changing, and no-op proposals are rejected.
The `__imp_type__` key is reserved at every depth for Imp's durable wire tags.

Structured mode currently rejects refiners, merge, external tracking, custom
callbacks, and custom candidate/module selectors because those extensions
consume GEPA's text-component representation. Built-in selection, caching,
atomic checkpoints, resume, and best-output persistence remain supported.

Evaluators may return a numeric score or `{score, side_information}`. Side
information can contain component-specific feedback, objective subscores, and
typed images. Config controls candidate and module selection, refinement,
perfect-score skipping, merge, stopping, metric/reflection budgets, bounded
concurrency, and callbacks. Custom selectors implement the documented GEPA
selector behaviours rather than being special-cased in the runner; the
structured-mode restriction above prevents an encoded internal candidate from
being mistaken for the user artifact.

For an external batch backend, pass `nil` as the scalar evaluator and provide
`batch_evaluator:`. The callback receives every pending `{candidate, example}`
pair in deterministic order and must return one aligned score or
`{score, side_information}` per pair. An arity-two callback additionally
receives aligned optimization-state values. String candidates are unwrapped,
single-task examples are `nil`, and structured candidates remain native.
Providing both transports routes grouped work through the batch callback while
refiner singleton work uses the scalar evaluator. A legacy
`{score, ignored_output, side_information}` result is accepted, but its output
slot cannot replace candidate identity.

With `raise_on_exception: false`, a whole callback failure or explicit
`{:error, reason}` row is retained as aligned score-zero diagnostics. Such an
incomplete seed aborts; an incomplete proposed or validation candidate is
rejected and never cached or selected. This containment is a deliberate safety
extension to the pinned v0.1.4 batch surface. Callback shape errors such as a
wrong result count remain fatal.

The pinned custom batch-sampler boundary is exposed as the
`Imp.Optimizer.GEPA.BatchSampler` behaviour. Put an implementing struct in
`reflection: [batch_sampler: sampler]`; the sampler supplies its own positive
minibatch size and returns ordered training indexes with updated state. Imp
persists that state and a stable consumer-defined identity in every engine
checkpoint, refuses strategy substitution on resume, and never silently falls
back to `:epoch_shuffled`. As upstream does, a custom sampler cannot be combined
with `reflection_minibatch_size`.

For multiple proposals in one round, set `engine.sampling_strategy` to
`{:same_parent, n}`, `{:independent, n}`, or `{:pxn, parents, mutations}` and
choose `engine.selection_strategy` (`:all_improvements`, `:best_improvement`,
or `{:top_k, n}`). `engine.acceptance_criterion` controls the preceding
admission judgement with `:strict_improvement`, `:improvement_or_equal`, or an
`Imp.Optimizer.GEPA.Acceptance.callback/1`. BEAM-native selection callbacks
are also supported. The strategy configuration is checkpoint-bound, so resume
cannot silently switch policies with the same task width. Arbitrary Python
strategy objects have no native callback contract and are rejected explicitly.

The returned result remains immutable, matching the pinned public result
boundary. Use `Imp.Optimize.Anything.best_candidate/1` to obtain the native
selected value, install it into the consumer's actual program/configuration,
and execute that program. Imp does not advertise an implicit object-mutation
or application callback.

When `run_dir` is set, Imp writes atomic JSON checkpoints and seed/best
validation outputs. Evaluation caching defaults to durable, content-addressed
JSON storage for run directories and fails closed on corrupt or incompatible
entries. Without a run directory, enabled caching is in-memory. Persisted
config and results use tagged JSON codecs; W&B credentials are never written.

External tracking is optional:

```elixir
config = [
  engine: [max_candidate_proposals: 10, run_dir: "tmp/anything-run"],
  tracking: [
    use_wandb: true,
    wandb_init_kwargs: %{project: "artifact-optimization"},
    use_mlflow: true,
    mlflow_tracking_uri: "http://127.0.0.1:5000",
    mlflow_experiment_name: "artifact-optimization"
  ]
]

Imp.Optimize.Anything.run(seed, evaluator, config: config)
```

W&B reads `WANDB_API_KEY` unless `wandb_api_key` is supplied at runtime.
MLflow supports `MLFLOW_TRACKING_TOKEN` or the standard username/password
environment variables. Backend startup failures abort the run; later logging
or finish failures are warnings. Imp reports accurate failed terminal status,
while the isolated W&B client can reproduce GEPA v0.1.1's success-only finish
behavior when explicitly configured for compatibility.

The source-checkout effectiveness target uses executable code, agent
configuration, and scheduling artifacts:

```sh
mix benchmark.optimize_anything.check
mix imp.benchmark.optimize_anything --live --provider openai \
  --model gpt-5.4-2026-03-05 \
  --pricing-profile openai-gpt-5.4-standard-2026-03-05 \
  --seeds 17,23,31 --max-proposals 5 \
  --max-cost-usd 0.50 --max-requests 20 \
  --max-input-tokens 100000 --max-output-tokens 20000 \
  --max-output-tokens-per-request 1000 \
  --out benchmarks/runs/optimize-anything
```

The smoke command validates wiring only. The source-checkout benchmark guide
defines the multi-seed, three-split held-out evaluation, cost, and checkpoint
requirements for the still-open scoped live effectiveness claim. The immutable
pre-v2 artifact is T2 execution evidence only because it reused its development
set for final scoring. The live command requires
all spend and token ceilings explicitly, reserves worst-case request cost
before transport, disables cache hits and transport retries, and records a
checksummed budget checkpoint; missing or zero provider cost telemetry aborts
the campaign. A provider-reported final-call overrun is retained in the
checkpoint but cannot produce full evidence. The pinned price profile is bound
to the exact provider/model snapshot and the official OpenAI pricing source.
The final checkpoint envelope is embedded and validated without relying on its
informational local path. Persistence is a sync-write plus rename of the latest
snapshot, not an append-only log, resumable spend state, directory-fsync, or
power-loss guarantee. Existing run ids are refused; after a process restart,
review the checkpoint and launch a new run id with a fresh limit. The separate
$15 matched-upstream research maximum is not the $0.50 ceiling for this narrow
rerun and does not authorize an additional asserted product claim.

Current implementation fidelity is pinned to GEPA v0.1.4; earlier comparisons
against the v0.1.1 checkout are kept as history in the repository's internal
notes, which also track how each pinned upstream commit is recorded.

## Tools And MCP

Tools are ordinary structs called directly or handed to react-family
programs under a `tool_policy:`; the API guide's agent-spectrum section
covers when each loop shape earns its place.

MCP catalogs import external schemas into ordinary `Imp.Tool` structs. Schemas
use the MCP spec dialect (camelCase `"inputSchema"`, optional `"description"`);
in-process catalogs may also use snake_case `:input_schema` as a back-compat
fallback:

```elixir
catalog =
  Imp.MCP.Catalog.new([
    %{"name" => "lookup", "inputSchema" => %{"required" => ["key"]}, "run" => & &1}
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
do not train models in-process. SFT trainer options accept `nil`, a trainer
module, a configured trainer struct, or an arity-3 callback so tests and
applications can inject that single-call boundary without ambient provider
state. GRPO requires a trainer module or struct because its reinforcement
lifecycle spans start, status, step, termination, and artifact callbacks.

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

## What The Shipped Tests Promise

Imp's repository keeps its benchmark and evidence tooling out of the
application API; what ships is behavior covered by deterministic regression
tests. That coverage includes:

- Ax-style structured extraction with schema constraints.
- Agent/tool execution with trace evidence.
- GEPA prompt optimization.
- Program optimization with a scripted reward where the baseline fails and the
  compiled program passes.
- Arbitrary config optimization.

## Production Boundaries

Advanced Imp APIs are part of the same release contract as the core facade:
they must pass deterministic tests, compile with warnings as errors, preserve
JSON-safe persistence where applicable, and keep provider credentials out of
saved artifacts.

MCP support covers catalog import plus JSON-RPC HTTP, stdio, and Streamable HTTP
clients. The bundled benchmark tests are deterministic regression checks on
Imp behavior, not public leaderboard claims. Provider-native schema APIs and
streaming are explicit provider responsibilities layered over the shared Imp
contracts and tested through injectable transports.

For real dataset benchmark evidence, use the maintainer evidence notes in the
source repository. That lane fetches canonical GSM8K/HotPotQA rows, writes
manifests and result artifacts, and keeps research evidence separate from the
normal product gate.

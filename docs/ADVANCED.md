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
callbacks, reflection strategies, and custom candidate/module selectors because those extensions
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

For pinned GEPA v0.1.4 text candidates, `reflection.reflection_strategy` accepts
a module exporting `reflect/3`, an arity-three function, or a contextual
`Imp.Optimizer.GEPA.ReflectionStrategy`. The strategy owns proposal generation
and therefore does not require `reflection_lm`. Its stable identity and
contextual state are bound into the engine checkpoint, so JSON resume refuses
strategy drift before evaluation. Executable strategy references remain trusted
runtime bindings: persist the result checkpoint and supply the same strategy on
resume rather than serializing it inside the nested config.

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

The source checkout includes an ordinary real-model program under
`examples/local_gepa_banking77`. Its analyzer and classifier use different
local runtimes; the classifier is a verified retained MLX SFT artifact. The
example runs a bounded GEPA proposal on frozen train/selection rows, evaluates
the selected program on untouched rows, writes the parameter-only artifact,
and reconstructs the trusted program in a fresh OS BEAM. Its retained exercised
result is neutral: the real proposal scored below the baseline, selection kept
the baseline instructions, and the 40-row selected output reproduced exactly.
That is operational lifecycle evidence, not optimizer lift.

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

### Optional local TRL GRPO

`Imp.Clients.TRLTrainer` is a local Apple-Silicon backend for real LoRA GRPO
updates. Its default one-step contract pins Qwen2.5-0.5B-Instruct at revision
`7ae557604adf67be50417f59c2c2f167def9a775`, CPython 3.12, TRL 1.6.0,
Transformers 4.57.6, PEFT 0.18.1, and PyTorch 2.10.0 on MPS with CPU fallback
disabled. Imp does not install those dependencies or download the model.

```elixir
trainer =
  Imp.Clients.TRLTrainer.new(
    python: "/path/to/pinned-venv/bin/python",
    model_path: "/path/to/pinned-qwen-snapshot",
    root: "var/trl-sessions"
  )

{:ok, base} = Imp.Clients.TRLDeployment.start_base(trainer)
baseline_program = Imp.with_lm(program, base.lm)
{:ok, baseline_prediction} = Imp.call(baseline_program, inputs)
:ok = Imp.Clients.TRLDeployment.stop(base)

grpo =
  Imp.Optimizer.GRPO.new(reward,
    trainer: trainer,
    num_train_steps: 1,
    num_rollouts_per_grpo_step: 4,
    train_kwargs: [learning_rate: 1.0e-6, loss_type: :dapo],
    checkpoint_selection: :best_validation
  )

{:ok, result} = Imp.train(program, grpo, trainset, validation: selection_set)
```

The training worker is deliberately terminated when the job completes. To use
the saved LoRA later, load the credential-free job and a portable copy of the
original program in the new process, reconstruct the trusted local trainer
configuration, and rebind explicitly:

```elixir
job = Imp.Clients.TrainingJob.load!("var/trl-job.json")
program = Imp.load!("var/base-program.json")

trainer =
  Imp.Clients.TRLTrainer.new(
    python: "/path/to/pinned-venv/bin/python",
    model_path: "/path/to/pinned-qwen-snapshot",
    root: "var/trl-deployments"
  )

{:ok, trained} =
  Imp.Clients.TrainingJob.rebind(job, program, trainer: trainer)

{:ok, prediction} = Imp.call(trained, inputs)
:ok = Imp.Clients.TRLDeployment.stop(job)
```

Imp does not restore executable paths from the job. Rebind verifies every
artifact byte, loads the adapter into the pinned base model, and requires the
loaded LoRA tensor digest to match the training observation. Every generation
also carries and rechecks the exact artifact identity. A TRL job without the
explicit trusted `:trainer` therefore fails instead of returning an artifact-
named LM backed by no running model.

The default worker accepts any Imp-rendered prompt and finite external reward;
it does not require Banking77, opaque route labels, binary rewards, or a tensor
change. Uniform group rewards are a valid GRPO no-op and are recorded honestly.
The retained controlled-rollout contract separately requires non-uniform
rewards, advantages, and changed tensors as conformance assertions. Rollout
count and the exactly-one-step budget are checked before model loading.
Prompt groups carry their selected source-row identity and are ordered
group-major through official TRL, so group-relative advantages remain separate.
`qwen-two-step-contract.json` demonstrates a longer durable session: step two
loads the step-one adapter and resumes the exact official optimizer, scheduler,
Trainer state, and separately retained MPS RNG. Every step is immutable and the
final standalone artifact includes the complete update/receipt chain. A fresh
worker verifies that chain and reloads the latest adapter before it advertises
the next step. Repeating independent one-step jobs is not equivalent and is not
used as a continuation path.

`train_kwargs` is not an arbitrary Python escape hatch. The local backend
accepts only `learning_rate`, `beta`, `loss_type` (`:grpo`, `:dr_grpo`, `:dapo`,
or `:bnpo`), and `scale_rewards` (`:group`, `:batch`, `:none`, `true`, or
`false`). It validates them before model startup, writes an owned session
contract, and binds their normalized content into both protocol and durable
resume identity. Unknown or changed settings fail closed; device, model, LoRA,
step/generation budgets, filesystem paths, and executable behavior remain
contract-owned. In particular, Imp does not expose TRL's CISPO loss as native
CISPO product support through this option.

The default checkpoint selection is `:latest`. With
`checkpoint_selection: :best_validation`, Imp evaluates each due trained
checkpoint on the declared validation set, maximizes the finite scalar score,
and keeps the earliest checkpoint on ties. The bundled TRL LM evaluates
greedily even though training rollouts remain sampled. Every validation and the
selected artifact identity survive durable resume; selection resolves and
content-verifies the retained artifact before program rebind. The final trainer
state is preserved separately so an earlier deployable winner does not rewrite
training history. This selector intentionally excludes the base program and
untouched test data—compare base as a separate selection arm if the product
must be able to decline training altogether.

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
{:ok, trained_program} = Imp.Clients.TrainingJob.rebind(job, program)
{:ok, prediction} = Imp.call(trained_program, %{question: "..."})
```

The proven 80-example configuration produced 72 training and 8 validation rows
stratified by `route`, with prompt masking, 8 LoRA layers, batch size 1,
gradient accumulation 4, 216 iterations, learning rate `1.0e-4`, maximum
sequence length 512, and seed 0. These are the trainer defaults except
`stratify_by`, which remains generic and must be set to `[:route]` by this
campaign. MLX-LM receives gradient accumulation through its pinned 0.31.3
`--grad-accumulation-steps` option.

The pinned model snapshot, LoRA adapter, and returned fused directory are
separate artifacts. The trainer reports success only after the adapter config
and weights are hashed, the official `mlx_lm.fuse` command succeeds, the whole
fused tree is inventoried, required model/config files exist, and the fused-tree
digest differs from the base-tree digest. `job.result_model` is the canonical
fused directory; the adapter remains available through
`job.metadata.adapter_path`. A failed or interrupted fusion resumes from the
verified adapter without repeating the SFT command, while an adapter mutation,
partial fused tree, base-identical tree, or manifest mutation fails closed.

`TrainingJob.rebind/3` verifies those contents again, starts the manifest-bound
`mlx_lm.server` under the Imp supervisor, requires `/v1/models` to advertise the
exact canonical fused path, and pins the program to the returned ReqLLM. Each
server receives a new empty, deployment-owned Hugging Face/Transformers cache
environment while the verified artifact is supplied by explicit local path.
Ambient cached models therefore cannot enter the server catalog, and the owned
cache is removed with the supervised process group on failure or stop. Use
`Imp.Clients.MLXLMDeployment.stop(job)` when the local server is no longer
needed. Application shutdown also tears down its complete external process
group. Commands are invoked directly with argument vectors, never through a
shell. For a pinned `uvx` launcher, the trainer derives `mlx_lm.fuse` and
`mlx_lm.server` by replacing the final `mlx_lm.lora` argument; explicit
`fuse_executable`/`fuse_executable_args` and
`server_executable`/`server_executable_args` pairs override that derivation.
Those commands are executable local configuration. A manifest checksum proves
integrity, not provenance: load and rebind MLX training jobs only from trusted
runs whose recorded command and artifact paths you control.

Rebinding has an explicit ownership boundary. The verified job owns the trained
artifact, provider, served model identity, and server endpoint. The trusted
incoming program retains its adapter and parsing configuration, while its
allowlisted ReqLLM call controls—including `cache`, `temperature`, token limits,
timeouts, and explicit retry/`req_http_options` settings—are applied to the new
artifact-bound client. Provider, model, endpoint, credential, unknown-option,
and malformed retry-policy conflicts fail before the MLX server starts. Rebind
never silently restores caching or retries that the source program disabled.

Training jobs and rebound programs remain checksummed, credential-free data:

```elixir
:ok = Imp.Clients.TrainingJob.save!(job, "training-job.json")
:ok = Imp.save!(trained_program, "trained-program.json")

# In a fresh BEAM process, rebind once to verify and restart the exact artifact.
job = Imp.Clients.TrainingJob.load!("training-job.json")
program = Imp.load!("trained-program.json")
{:ok, program} = Imp.Clients.TrainingJob.rebind(job, program)
{:ok, prediction} = Imp.call(program, %{question: "..."})
:ok = Imp.Clients.MLXLMDeployment.stop(job)
```

The deployment and fusion path is SFT infrastructure. It does not implement a
GRPO update, and a changed fused-tree digest alone is not evidence of useful
trained behavior. The completed acceptance compared the pinned base and fused
model on 40 untouched rows from a frozen four-intent Banking77 subset, then
required a fresh-process consumer to reproduce the fused ordered predictions
and errors byte-for-byte.

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

The source-checkout campaign validates immutable dataset and model-tree inputs,
matched evaluation, fusion, deployment rebinding, checksummed save/load, and
server cleanup. A passing artifact supports only its pinned model, task, split,
and run; it does not establish general SFT or BetterTogether effectiveness.

The preserved public-consumer acceptance at commit `dd6f6ad` used one pinned
Qwen2.5-0.5B MLX SFT artifact and the frozen four-intent Banking77 subset. On
the 40 untouched rows, accuracy improved from `0.125` to `0.55` and macro-F1
from `0.0610` to `0.4561`. The saved program loaded and served the exact fused
artifact in a fresh OS BEAM with byte-identical ordered predictions and errors.
This is one-model, one-task evidence; it does not establish general Imp or SFT
effectiveness, GRPO, production reliability, or BEAM superiority.

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

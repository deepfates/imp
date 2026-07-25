# Operations Reference

This reference covers the contract-heavy operations that sit beyond ordinary
inference: durable optimizer resume, provider training-job lifecycle and
dispatch journals, Fast-Slow training, resumable provider batches, and advanced
MCP transports. Each requires explicit service ownership, credentials, payload
contracts, and protocol-specific tests. The task-oriented cookbook is the
[API Guide](API_GUIDE.md); start there and come here when a program needs one of
these boundaries.

These operations exercise real transport, process trees, and artifact
round-trips, and what they prove is protocol-level: that Imp's wire contracts,
resumption, and durability behave correctly against local and
provider-compatible boundaries. They do not by themselves establish that a paid
provider ran your specific job, or that an optimizer improved your task — that is
the difference between a faithful boundary and a live outcome. Whether any
capability here has been proven effective, and to what rung, is recorded in
[Evidence](EVIDENCE.md).

## Durable Run-Level Resume

The MIPROv2 and SIMBA checkpoint examples in the [API Guide](API_GUIDE.md) pause
at durable run boundaries and resume from the JSON-safe checkpoint attached to
the optimizer report. This is the contract behind that surface.

`max_trials:` and the compile-time `max_steps:` cap only the new work performed
by that invocation; the total run budgets remain `num_trials` and the SIMBA
optimizer's configured `max_steps`. Reports expose `metadata.run_status` as
`:paused` or `:complete`, `metadata.resumed`, progress counters, and the latest
`metadata.resume_state`. MIPROv2 checkpoints after setup and each completed
trial. SIMBA checkpoints before search, after each completed step, and after
each completed finalist evaluation. Completed boundaries are not replayed;
interrupted in-flight work is retried.

Checkpoints do not serialize executable callbacks or live LM clients. Resume
with the original program shape, datasets, and search configuration, while
supplying the current metric and LM callbacks through the runtime optimizer and
program. This deliberately allows callback captures such as process handles or
credentials to be rebound. Run-configuration hashes and payload checksums reject
accidental mismatch or mutation, but they are not signatures, authentication,
encryption, or a sandbox. Checkpoints can contain instructions, demos, outputs,
and error details: store them as sensitive data, accept them only from a trusted
run, and make `checkpoint_fn` persistence atomic when crash durability matters.

## Provider Training

Training optimizers are intentionally separate from program optimizers. Execute
`BootstrapFinetune` and `GRPO` with `Imp.train/3` or `Imp.train/4`, not
`Imp.optimize`:

```elixir
trainer = MyApp.training_backend()
optimizer = Imp.Optimizer.BootstrapFinetune.new(metric, trainer: trainer)

{:ok, training} = Imp.train(program, optimizer, trainset)
```

`Imp.train/3` and `Imp.train/4` return
`{:ok, %Imp.Optimizer.TrainingResult{}}` or
`{:error, reason}`. Bootstrap fine-tuning reports `status: :job_created` for an
asynchronous provider job and `status: :completed` with a rebound program when
the trainer returns a successful terminal job. Terminal failures remain errors.
GRPO reports `status: :completed` after its synchronous trainer workflow returns
the rebound program. Both require an explicitly configured
trainer. Imp does not silently fall back to local training when no trainer is
configured. `Imp.Clients.MLXLMTrainer` is an optional, explicit local SFT
backend, not a fallback or a GRPO engine. Its successful outcome is an official
fused model tree whose complete contents are verified before a supervised local
server can be rebound as ReqLLM. The arity-3 trainer callback shorthand implements
only the single-call SFT boundary; GRPO needs a trainer module or struct implementing
the reinforcement lifecycle callbacks. Trainsets and GRPO validation sets may
be any finite `Enumerable`, including streams; Imp materializes each once before
the multi-step training workflow. A training optimizer that declares optional
validation accepts it as `validation:` in the fourth-argument keyword options.

Provider training jobs can be refreshed, cancelled when the provider exposes a
cancellation endpoint, saved without credentials, restored with an explicitly
reinjected transport and API key, and rebound to a compiled program only after
the provider reports a non-empty model artifact. Submit, refresh, and cancel
requests use stable idempotency keys and bounded retries. These lifecycle APIs
classify documented provider states before cleanup: known active jobs may be
cancelled, known terminal jobs are preserved, and unknown states fail closed
without a destructive cancellation guess. From a source checkout, the
source-checkout-only `mix protocol.training.check` gate exercises the provider
wire contracts locally.

### Dispatch Journals

Direct provider submissions can close the accepted-submit/lost-handle crash
window by passing `dispatch_journal_path:` to `Imp.Clients.Trainer.finetune/4`.
Imp writes a credential-free prepared intent before dispatch, uses a stable
derived idempotency identity, and atomically commits the returned
`Imp.Clients.TrainingJob` before returning it. A trainer may implement
`reconcile_finetune/2` (or module callback `reconcile_finetune/1`) to recover an
accepted job after an ambiguous caller crash. If reconciliation is unavailable,
an ambiguous dispatch fails closed instead of risking a duplicate provider job.
Reuse a journal only with the same trainer identity, model, examples, and
semantic options; mismatches are rejected.

Calls sharing one journal path are serialized inside the current BEAM node, so
concurrent callers cannot independently submit the same prepared intent. A
submitted or reconciled job must carry the exact derived idempotency identity;
a different identity is rejected and never committed. Committed custom-provider
jobs are reconciled again to rebuild process-local runtime state. If that
provider cannot reconcile, resume fails explicitly instead of returning a
handle whose callbacks or transport were lost.

Journal payloads exclude credentials, callbacks, PIDs, and transports. Endpoint,
provider, model, method, examples, and other semantic configuration remain
identity-bound. A credential-bearing job ID, provider/model artifact locator, or
status/cancel URL makes safe resumability impossible and therefore fails closed
before the job handle is persisted. The same-directory sync-write-and-rename
protocol plus checksum covers cooperative callers and ordinary BEAM process
crashes. It does not claim protection from adversarial local writers, host power
loss, filesystem failure, or concurrent writers outside this API.

## Fast-Slow Training

Fast-Slow Training has a separate provider-neutral orchestration surface. Build
immutable configuration and state with `Imp.Training.FastSlow.Config` and
`State`, then execute paper-ordered cycles through
`Imp.Training.FastSlow.Runner` and a module implementing
`Imp.Training.FastSlow.Backend`. Each cycle prefetches exactly `T` minibatches,
runs the GEPA fast phase once, allocates exactly `G / K` rollouts to each of the
`K` retained prompts per question, and keeps that population fixed through the
`T` slow-update handoffs.

The checkpoint callback receives `%{state: state, runner_context: context}`.
Persist `state` with `Imp.Training.FastSlow.Checkpoint` and persist the supplied
context map alongside it; `Runner.load_context!/2` verifies the actual
minibatch content digests against the state's lookahead. Backend context must be
credential-free, JSON-safe data. A backend must return `true` from
`replay_safe?/2` only after proving the provider effect is idempotent under the
operation intent or that the earlier attempt was not applied. Otherwise resume
fails with `:ambiguous_external_outcome` instead of duplicating a rollout or
weight update.

The shared `Imp.Clients.Trainer` reinforcement boundary accepts the resulting
token-aligned trajectories, including behavior-policy token log probabilities,
response token IDs and masks, reward, and normalized advantage. The runner is a
paper-ordered BEAM orchestration adaptation, not a bundled weight trainer.
`Backend.update_slow/5` is only a handoff: Imp does not compute or verify the
CISPO importance ratio, clipping, loss, gradient, optimizer step, or resulting
model weights. Passing `objective: :cispo` to a trainer preserves the requested
objective at that boundary but cannot prove that an arbitrary trainer honored
it. A backend that advertises CISPO owns that implementation and must return a
content-bound identity for every resulting policy.

`State.new!/4` accepts an `operations` budget (one unit per new durable provider
intent). The runner stops before dispatch when that budget is exhausted, and it
records ordered `operation.intent`, `operation.confirmed`,
`operation.retryable`, and `budget.exhausted` events in the checkpointed state.
Retries of an existing intent do not consume a second unit. These contracts are
operational controls; they are not CISPO execution or optimizer-effectiveness
evidence.

## Resumable Provider Batches

Use `Imp.Clients.ReqLLMBatch` when a collection of independent provider calls
must survive process or host restarts. Each request needs a stable, unique ID
and a JSON-safe payload. The callback is provider-neutral and reports an
explicit outcome so retry policy does not depend on provider-specific structs:

```elixir
alias Imp.Clients.ReqLLMBatch

requests = [
  %{id: "question-001", payload: %{question: "Capital of France?"}},
  %{id: "question-002", payload: %{question: "Capital of Italy?"}}
]

dispatch = fn request, _context ->
  case MyProvider.complete(request.payload, idempotency_key: request.id) do
    {:ok, output} -> {:ok, output}
    {:error, :rate_limited} -> {:transient, :rate_limited}
    {:error, :unauthorized} -> {:terminal, :unauthorized}
    {:error, reason} -> {:malformed, reason}
  end
end

{:ok, summary} =
  ReqLLMBatch.run(requests, dispatch,
    checkpoint: "var/question-batch.json",
    max_concurrency: 4,
    max_attempts: 3
  )
```

Only `:transient` outcomes retry, and every dispatch consumes an attempt. A
callback exception, throw, task exit, or timeout is recorded as transient.
`:terminal` and `:malformed` outcomes do not retry. `validate_output:` can turn
an otherwise successful return into a malformed outcome at the commit boundary.

The checkpoint records append-only request, dispatch-intent, outcome, and
resume-reconciliation events. Each update is written to a synced temporary file
and atomically renamed. Resume uses the persisted request order, attempt counts,
and retry limit:

Checkpoints contain the JSON-safe request payloads, provider outputs, and failure
details needed for audit and resume. Treat the checkpoint directory as
application data: restrict access, apply the application's retention policy, and
do not place credentials in request payloads.

```elixir
{:ok, summary} =
  ReqLLMBatch.resume("var/question-batch.json", dispatch,
    max_concurrency: 4
  )
```

A committed success is never replayed. If a checkpoint contains a dispatch
intent without a committed outcome, resume marks that request `:ambiguous` and
does not send it again. Resolve that state using provider-side idempotency or
reconciliation before starting a new request; Imp deliberately cannot infer
whether the remote provider accepted an interrupted call.

For ReqLLM, the included adapter works with any model spec supported by the
client. Its default classification treats ReqLLM errors as transient; use a
custom callback when application knowledge can classify errors more narrowly.

```elixir
client = Imp.Clients.ReqLLM.new("gemini:gemini-2.5-flash", api_key: api_key)
dispatch = ReqLLMBatch.req_llm_dispatcher(client, temperature: 0)

requests = [
  %{
    id: "question-001",
    payload: %{messages: [%{role: :user, content: "Capital of France?"}]}
  }
]

ReqLLMBatch.run(requests, dispatch, checkpoint: "var/req-llm-batch.json")
```

## Advanced MCP Transports

Beyond the in-process catalog and HTTP-backed discovery shown in the
[API Guide](API_GUIDE.md), Imp ships stdio and Streamable HTTP MCP transports.
For stdio or Streamable HTTP transports, point Imp at trusted services you own:

```elixir
stdio = Imp.MCP.StdioClient.new("/path/to/server", args: ["--stdio"])
streamable = Imp.MCP.StreamableHTTPClient.new("https://mcp.example/mcp")
```

Both transports run the MCP lifecycle handshake: a full `initialize` request
(protocol version, capabilities, client info) followed by the
`notifications/initialized` notification. The Streamable HTTP client captures a
server-assigned `Mcp-Session-Id` from the initialize response and sends it on
every later request; pass `session_id:` only to resume a known session (a
server-assigned id supersedes it).

Only connect MCP stdio clients to trusted local executables. The stdio client
opens a process for discovery and opens a fresh process for each imported tool
call. Imp treats MCP tools like ordinary `Imp.Tool` values, so use tool
policies for anything with side effects.

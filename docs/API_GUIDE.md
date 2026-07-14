# API Guide

This guide is organized around the things you build.

Most examples use the public `DSEx` facade. Reach for deeper `DSEx.*` modules
when you need direct control over adapters, optimizer reports, tools, agents, or
persistence. The canonical path is:

`signature -> program -> call -> evaluate -> optimize -> tools/agents -> operate`

## Configure An LM

For deterministic examples:

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)
```

Programs built without explicit `:lm` or `:adapter` resolve settings when they
are called, so a later `DSEx.configure/1` or scoped `DSEx.context/2` affects
existing programs. Pass `lm:` or `adapter:` to pin a program to a specific
runtime dependency.

Explicit `lm:` values are checked when the program is built. DSEx accepts
`nil`, an LM module, an LM struct, a configured `%{module: module, opts:
keyword}` map, or an arity-2 callback. Explicit `adapter:` values accept `nil`
or a module exporting `format/3` and `parse/3`. Omit the option when you want
dynamic settings; pass the option when you want a self-contained program.

For production provider access, use the ReqLLM-backed client:

```elixir
model = System.fetch_env!("OPENAI_MODEL")
api_key = System.fetch_env!("OPENAI_API_KEY")

lm = DSEx.req_llm("openai:#{model}", api_key: api_key, temperature: 0)
DSEx.configure(lm: lm)
```

This delegates provider/model lookup, Req/Finch transport, streaming, and
provider option translation to the Elixir `req_llm` ecosystem. DSEx still owns
the signature, adapter, optimizer, evaluation, and trace vocabulary.

For a runnable real-provider walkthrough, open
`livebooks/01_real_lm_front_door.livemd`. It is the best first stop after this
guide when you want the "this is actually an LM program" moment.

### Run A Resumable Provider Batch

Use `DSEx.Clients.ReqLLMBatch` when a collection of independent provider calls
must survive process or host restarts. Each request needs a stable, unique ID
and a JSON-safe payload. The callback is provider-neutral and reports an
explicit outcome so retry policy does not depend on provider-specific structs:

```elixir
alias DSEx.Clients.ReqLLMBatch

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
reconciliation before starting a new request; DSEx deliberately cannot infer
whether the remote provider accepted an interrupted call.

For ReqLLM, the included adapter works with any model spec supported by the
client. Its default classification treats ReqLLM errors as transient; use a
custom callback when application knowledge can classify errors more narrowly.

```elixir
client = DSEx.Clients.ReqLLM.new("gemini:gemini-2.5-flash", api_key: api_key)
dispatch = ReqLLMBatch.req_llm_dispatcher(client, temperature: 0)

requests = [
  %{
    id: "question-001",
    payload: %{messages: [%{role: :user, content: "Capital of France?"}]}
  }
]

ReqLLMBatch.run(requests, dispatch, checkpoint: "var/req-llm-batch.json")
```

## Basic Predict

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program =
  "question -> answer: short_span"
  |> DSEx.signature(
    "Answer with the shortest correct span. Do not explain."
  )
  |> DSEx.predict(lm: lm)

{:ok, pred} = DSEx.call(program, %{question: "Capital of France?"})
DSEx.get(pred, :answer)
```

## Handle Failures

Program calls return tagged tuples. Match both branches at application
boundaries instead of assuming every provider call succeeds:

```elixir
case DSEx.call(program, %{question: question}) do
  {:ok, prediction} ->
    {:ok, DSEx.get(prediction, :answer)}

  {:error, reason} ->
    Logger.warning("DSEx call failed", reason: inspect(reason))
    {:error, :language_model_unavailable}
end
```

Missing inputs, provider failures, malformed provider returns, and exhausted
adapter retries are returned as `{:error, reason}`. Invalid constructor options
and unsupported program shapes raise `ArgumentError` because they are local
configuration defects and should fail before serving traffic.

Evaluation keeps per-example failures visible rather than hiding them:

```elixir
report = DSEx.evaluate(program, devset, metric, failure_score: 0.0, max_errors: 5)

Enum.each(report.errors, fn error ->
  Logger.warning("DSEx evaluation row failed", error: inspect(error))
end)
```

Use a finite `:max_errors` in production jobs to stop a systematically broken
campaign. Use `:infinity` only when collecting every failure is intentional.

## Conversation History

Use `DSEx.history/1` when a signature should see prior task turns. History is
signature-shaped data, not provider chat logs: each turn is a field map with the
same input/output names the program already understands.

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Rome"} end]
}

program = DSEx.predict("question, history -> answer", lm: lm)

history =
  DSEx.history([
    %{question: "What is the capital of France?", answer: "Paris"},
    %{question: "What is the capital of Germany?", answer: "Berlin"}
  ])

{:ok, prediction} =
  DSEx.call(program, %{question: "What is the capital of Italy?", history: history})

DSEx.get(prediction, :answer)
```

The Chat adapter renders history turns before the current request, splitting
each turn into prior user/assistant messages according to the active signature.
`DSEx.History.dump/1` and `DSEx.History.load/1` give a JSON-safe boundary for
application state, while `DSEx.History.redact/1` supports safe inspection.
Provider-native role messages remain explicit as `DSEx.Adapters.Types.History`.

## The Canonical Path

Start with one typed program, evaluate it, attach examples, then optimize only
after the metric is meaningful:

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = DSEx.predict("question -> answer", lm: lm)

trainset = [
  DSEx.example(question: "Capital of France?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

devset = [
  DSEx.example(question: "Eiffel Tower city?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

metric = DSEx.exact_match(:answer)

baseline = DSEx.evaluate(program, devset, metric)

compiled =
  program
  |> DSEx.optimize(
    DSEx.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1),
    trainset,
    devset
  )

{baseline.score, DSEx.Optimizer.Report.fetch(compiled)}
```

Use deeper modules such as `DSEx.Evaluate` or `DSEx.Optimizer.RandomSearch`
directly when you need to hold evaluator structs, inspect optimizer internals,
or build custom orchestration. `DSEx.Evaluate.new/3` accepts
`max_concurrency:` for bounded parallel row evaluation while preserving row
order, process-local settings, feedback, metric metadata, and error budgeting.

## Which Program Shape?

| Use this | When |
| --- | --- |
| `DSEx.predict/2` | One model call maps named inputs to named outputs. |
| `DSEx.chain_of_thought/2` | You want a reasoning field before the final answer. |
| `DSEx.multi_chain_comparison/2` | You already have candidate completions and want a self-consistency chooser. |
| `DSEx.best_of_n/3` | You want to run one program several times and keep the highest-scored result. |
| `DSEx.refine/3` | You want bounded retry with feedback until a metric passes. |
| `DSEx.assert/3` | You want named runtime constraints to produce feedback and self-repair attempts. |
| `DSEx.parallel/3` | You want supervised concurrent batch calls with one result per input. |
| `DSEx.knn/3`, `DSEx.nearest/2` | You want nearest-neighbor examples from a local trainset. |
| `DSEx.react/3` | The model should choose tools and then submit a validated answer. |
| `DSEx.program_of_thought/2` | The model should write small sandboxed Elixir snippets. |
| `DSEx.code_act/3` | You want interleaved tool/code execution under a policy. |
| `DSEx.rlm/2` | You need a bounded recursive controller for large-context exploration. |
| `DSEx.Agent` | You want an explicit Elixir agent runtime with tools and events. |

The later sections are there when your program needs more control, not because
every DSEx project should start with agents or recursive controllers.

## Composition Helpers

```elixir
lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
program = DSEx.predict("question -> answer", lm: lm)
metric = DSEx.exact_match(:answer)

{:ok, best} =
  program
  |> DSEx.best_of_n(metric, n: 2)
  |> DSEx.call(%{question: "2+2?"})

{:ok, refined} =
  program
  |> DSEx.refine(metric, max_attempts: 1)
  |> DSEx.call(%{question: "sqrt 16?"})

batch =
  DSEx.parallel(program, [%{question: "2+2?"}, %{question: "sqrt 16?"}],
    max_concurrency: 2
  )

{DSEx.get(best, :answer), DSEx.get(refined, :answer), length(batch)}
```

Use assertion-guided refinement when the constraint is clearer than a full task
metric:

```elixir
one_word =
  DSEx.assertion(:one_word, fn prediction ->
    prediction
    |> DSEx.get(:answer, "")
    |> to_string()
    |> String.split()
    |> length() == 1
  end, message: "Answer with one word.")

{:ok, constrained} =
  program
  |> DSEx.assert(one_word, max_attempts: 2)
  |> DSEx.call(%{question: "Capital of France?"})

{DSEx.get(constrained, :answer), DSEx.get(constrained, :assertion_score)}
```

`DSEx.multi_chain_comparison/2` is useful when candidate completions are
already available:

```elixir
chooser = DSEx.multi_chain_comparison("question -> answer", lm: lm, m: 2)

DSEx.call(chooser, %{
  question: "2+2?",
  completions: [
    %{reasoning: "addition", answer: "4"},
    %{reasoning: "counting", answer: "4"}
  ]
})
```

`DSEx.knn/3` builds a local nearest-neighbor predictor over examples. It returns
retrieved examples rather than a model prediction:

```elixir
trainset = [
  DSEx.example(question: "capital France", answer: "Paris") |> DSEx.with_inputs(:question)
]

knn = DSEx.knn(1, trainset, field: "question")
DSEx.nearest(knn, %{question: "France"})
```

## Request-Local Inference Search

`DSEx.Predict.Search.run/3` is the shared request-local engine for evaluating
explicitly identified inference candidates. It is an advanced module API, not
an optimizer and not a globally registered service. Every call owns its
candidate list, budget admission, tasks, outcomes, and provenance; no search
state survives the request.

```elixir
alias DSEx.Predict.Search
alias DSEx.Predict.Search.Candidate

candidates = [
  Candidate.new(:direct, %{answer: "Paris"}, %{calls: 1, cost_units: 1}),
  Candidate.new(:reasoned, %{answer: "Paris"}, %{calls: 1, cost_units: 2})
]

result =
  Search.run(
    candidates,
    fn candidate, context ->
      {:ok, candidate.value, score(candidate.value, context.outcomes)}
    end,
    mode: :sequential,
    threshold: 1.0,
    tie_policy: :first,
    budget: %{calls: 2, cost_units: 3}
  )
```

Candidate ids must be non-nil and unique. Projected budgets are
multidimensional non-negative maps. A finite budget admits only the longest
ordered prefix that fits; once a candidate exceeds any dimension, that
candidate and all later candidates are marked `:budget_exceeded`. The result
contains the selected `best` successful outcome, ordered `outcomes`,
full-list `provenance`, `stop_reason`, admitted projected budget, and the
executed outcomes' projected budget in `observed_budget`. The latter is not
provider billing or measured token usage. Record actual provider usage
separately when an evaluator can observe it.

The evaluator returns `{:ok, value, metric_result}` or `{:error, reason}`.
Metric results use normal `DSEx.Metrics` normalization. Exceptions, throws,
task exits, invalid returns, and timeouts become isolated failed outcomes.
Selection is highest score with explicit `:first` or `:last` tie policy;
threshold comparison is inclusive.

`:sequential` mode supplies prior ordered outcomes to the next evaluator and
stops before starting later candidates after reaching the threshold.
`:concurrent` mode uses supervised tasks with `max_concurrency:` and cannot
provide causal prior outcomes to concurrently evaluated candidates. A
threshold can cancel work that has not completed, but already completed
speculation remains in outcomes and projected-budget accounting. Result and
provenance order always follows candidate order, not task completion order.

`DSEx.Predict.BestOfN` delegates attempt execution and metric selection to this
engine in sequential, first-tie mode. It creates one projected `attempts: 1`
candidate per rollout, stops at its threshold, selects the highest-scoring
prediction, and optionally computes comparison feedback over successful
predictions.

`DSEx.Predict.Refine` keeps the same sequential, first-tie semantics but owns its
causal retry loop so it can enforce the DSPy `fail_count` boundary. After each
below-threshold success it asks the wrapped program's LM with the DSPy
`OfferFeedback` field contract: program and predictor definitions, inputs,
trajectory, outputs, reward contract, threshold, reward value, and module
names. The returned per-predictor advice becomes the next attempt's `hint_`.
Feedback inputs are redacted before the advice call. An explicit unary
`feedback_fn` takes precedence and receives
the ordered successful-attempt history, preserving the callback API. Threshold
comparison is inclusive, and exhaustion returns the highest-scoring successful
prediction rather than simply the last attempt. Automatic advice is keyed by
predictor name with an `N/A` fallback; program and module definitions are
redacted Elixir metadata representations, not claims of Python source-string
identity. The portable Refine artifact persists the program, metric callback,
explicit feedback callback, attempt count, threshold, and `fail_count`, while
old artifacts without the optional field load with the default budget.

## Chain Of Thought

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{reasoning: "add two and two", answer: "4"} end]
}

DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)

program = DSEx.chain_of_thought("question -> answer")
{:ok, pred} = DSEx.call(program, %{question: "2+2?"})

DSEx.get(pred, :reasoning)
DSEx.get(pred, :answer)
```

Manual reasoning fields are ordinary signature outputs. Provider-native
reasoning is separate: ReqLLM-backed providers can return thinking/reasoning
tokens, and DSEx preserves them in prediction metadata without pretending they
are a declared output field:

```elixir
{:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})

prediction.metadata[:native_reasoning]
prediction.metadata[:reasoning_details]
```

Streaming provider-native thinking chunks arrive as `%{reasoning: text}` chunks
with `metadata.type == :reasoning`; ordinary answer text still streams as text.
Outbound `DSEx.Adapters.Types.Reasoning` values become ReqLLM thinking content
parts for providers that support reasoning continuity.

## Schema-Constrained JSON

```elixir
signature =
  DSEx.signature(%{
    inputs: [:text],
    outputs: [
      %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })

program = DSEx.predict(signature, adapter: DSEx.Adapter.JSON)
```

The JSON adapter validates output fields and returns retry feedback for schema
violations.

Answer-shape constraints are useful for extractive tasks:

```elixir
signature =
  DSEx.signature(
    "question -> verdict: yes_no, amount: numeric_span, answer: short_span",
    "Extract only the requested answer fields."
  )
```

## Examples And Demos

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "4"} end]
}

demo =
  DSEx.example(question: "2+2?", answer: "4")
  |> DSEx.with_inputs(:question)

program =
  "question -> answer"
  |> DSEx.predict(lm: lm)
  |> DSEx.with_demos([demo])
```

## Evaluate A Program

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = DSEx.predict("question -> answer", lm: lm)

devset = [
  DSEx.example(question: "Capital of France?", answer: "Paris") |> DSEx.with_inputs(:question)
]

metric = DSEx.exact_match(:answer)
report = DSEx.evaluate(program, devset, metric)
report.score
```

Metrics may return booleans, numbers, maps with `:score` / `:feedback`, or a
`DSEx.Prediction` carrying score and feedback. DSEx normalizes those returns
into row scores, pass/fail state, feedback, and metric metadata. Arity-3 metrics
receive the prediction trace as their third argument.

Built-in metric helpers cover common benchmark shapes:

```elixir
qa = DSEx.extractive_qa("since 2000", "2000")

report =
  DSEx.classification_report([
    {"warm", "warm"},
    {"warm", "cool"},
    {"cool", "cool"}
  ])

{qa.metadata["f1"], report["macro_f1"]}
```

## Retrieval-Augmented Programs

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

docs = [
  %{text: "France has capital Paris."},
  %{text: "Germany has capital Berlin."}
]

retriever = DSEx.memory(docs, k: 1)

program =
  "question, context -> answer"
  |> DSEx.predict(lm: lm)
  |> DSEx.rag(retriever, k: 1)

{:ok, prediction} = DSEx.call(program, %{question: "capital France"})
DSEx.get(prediction, :answer)
prediction.metadata.retrieval
```

`DSEx.rag/3` is intentionally small: it retrieves documents, renders them into
the configured context field, calls the wrapped program, and records retrieval
metadata. The wrapped program can be a plain `Predict`, a compiled few-shot
program, or any other callable DSEx module that expects a context input. For
multi-hop retrieval, pass `hops: 2` or higher; each hop expands the original
query with previously retrieved passages, deduplicates documents, injects the
combined context, and records per-hop retrieval metadata.
RAG programs backed by `DSEx.memory/2` can be saved and loaded with
`DSEx.dump/1`, `DSEx.load/1`, `DSEx.save!/2`, and `DSEx.load!/1`; network
retrievers remain host-owned dependencies. Callback-bearing programs use a
named `DSEx.Saving.Registry` supplied explicitly by the host when dumping and
loading; functions are never written into artifacts.

## Local Embeddings

```elixir
{:ok, vectors} =
  DSEx.Embeddings.embed(
    DSEx.Embeddings.BagOfWords,
    ["elixir language model programs", "python prompt scripts"],
    dims: 8
  )

length(hd(vectors))
```

`DSEx.Embeddings.BagOfWords` is deterministic and local. It is useful for
examples, tests, and small retrieval experiments. Production semantic embeddings
should be injected behind the `DSEx.Embeddings` behaviour so credentials,
network calls, and model choice stay explicit. Any provider must return exactly
one numeric vector for each input text, in the same order.

## Optimize A Program

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = DSEx.predict("question -> answer", lm: lm)

trainset = [
  DSEx.example(question: "Capital of France?", answer: "Paris") |> DSEx.with_inputs(:question)
]

devset = [
  DSEx.example(question: "Eiffel Tower city?", answer: "Paris") |> DSEx.with_inputs(:question)
]

metric = DSEx.exact_match(:answer)
optimizer = DSEx.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
compiled = DSEx.optimize(program, optimizer, trainset, devset)

DSEx.Optimizer.Report.fetch(compiled)
```

The facade dispatches through the `DSEx.Optimizer` behaviour. Each optimizer
implements `__optimizer__/0` and `run/3`; `DSEx.optimizer_capabilities/1`
returns its validated declaration:

- `kind` is `:program`, `:training`, `:constructor`, or `:workflow`.
- `datasets` maps named splits such as `trainset`, `validation`,
  `promotionset`, and `auditset` to `:required`, `:optional`, or
  `:unsupported`.
- `result` declares the expected result shape.

Use `DSEx.optimize/3` when a program optimizer does not require validation,
`DSEx.optimize/4` when supplying validation, and `DSEx.optimize/5` when also
passing invocation options such as checkpoint controls. This choice follows the
declared split requirements; DSEx does not infer argument meaning from an
optimizer module's exported function arities. The behaviour layer checks that
required splits are present and unsupported splits are absent. Each optimizer
remains responsible for validating split contents and any optimizer-specific
relationship between them.

Use:

| Optimizer | Use it when |
| --- | --- |
| `LabeledFewShot` | You already have good examples and want demos quickly. |
| `BootstrapFewShot` | A teacher program can generate candidate demos. |
| `RandomSearch` / `BootstrapRS` | You want a small deterministic baseline search over demo sets. |
| `InstructionSearch` / `InferRules` / `COPRO` | Instructions or signature-level rules are the likely bottleneck. |
| `MIPROv2` / `SIMBA` | You want broader instruction/demo search with stronger evaluation discipline. |
| `GEPA` | You want DSEx-native GEPA-style reflection over program instructions, with comparative claims handled by the parity gates. |
| `Avatar` / `AvatarOptimizer` | You want bounded typed tool use and feedback-driven actor-instruction optimization from positive and negative trajectories. |
| `BetterTogether` | You want named prompt/weight optimizers applied in a configurable sequence, with every successful prefix evaluated and the best validation candidate retained. |

MIPROv2 and SIMBA can pause at durable run boundaries and resume from the
JSON-safe checkpoint attached to the optimizer report:

```elixir
checkpoint_path = Path.join(System.tmp_dir!(), "mipro-run.json")

persist = fn checkpoint ->
  temporary_path = checkpoint_path <> ".tmp"
  File.write!(temporary_path, Jason.encode!(checkpoint))
  File.rename!(temporary_path, checkpoint_path)
end

paused =
  DSEx.Optimizer.MIPROv2.compile(mipro, program, trainset, devset,
    max_trials: 2,
    checkpoint_fn: persist
  )

checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()

resumed =
  DSEx.Optimizer.MIPROv2.compile(mipro, program, trainset, devset,
    resume_state: checkpoint,
    checkpoint_fn: persist
  )
```

For SIMBA, use the corresponding five-argument call and invocation-level
`max_steps:` option:

```elixir
DSEx.Optimizer.SIMBA.compile(simba, program, trainset, devset,
  max_steps: 1,
  checkpoint_fn: persist
)
```

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
credentials to be rebound. Compatibility hashes and payload checksums reject
accidental mismatch or mutation, but they are not signatures, authentication,
encryption, or a sandbox. Checkpoints can contain instructions, demos, outputs,
and error details: store them as sensitive data, accept them only from a trusted
run, and make `checkpoint_fn` persistence atomic when crash durability matters.

Build an Avatar through the facade, then optimize its actor instruction with
the dedicated optimizer:

```elixir
lookup = DSEx.tool(:lookup, "Look up a country capital", &lookup_country/1)
avatar = DSEx.avatar("question -> answer", [lookup], lm: lm, max_iters: 3)

avatar_optimizer =
  DSEx.Optimizer.Avatar.new(DSEx.exact_match(:answer),
    comparator_lm: feedback_lm,
    rewrite_lm: rewrite_lm,
    max_iters: 2
  )

compiled_avatar = DSEx.optimize(avatar, avatar_optimizer, trainset)
```

Avatar records typed action observations, treats unknown, denied, and failed
tool calls as recoverable observations, and invokes a typed finalizer on
`Finish` or iteration exhaustion. AvatarOptimizer keeps a rewritten instruction
only when its trainset score improves. BetterTogether accepts named optimizers
and atom, string, or repeated list strategies; with validation it retains the
highest-scoring baseline/prefix candidate, and without validation it returns
the latest successful prefix. Its provider-backed weight step still does not
claim provider lifecycle completion or trained-model rebinding.

Optimizers that use an LM for proposal or reflection, such as COPRO, SIMBA,
and GEPA-style artifact optimization, use the same explicit LM shapes as
programs. `proposer_lm:`, `judge_lm:`, and `reflection_lm:` reject malformed
values when the optimizer is built or run, before a search loop starts.

Provider training jobs can be refreshed, cancelled when the provider exposes a
cancellation endpoint, saved without credentials, restored with an explicitly
reinjected transport and API key, and rebound to a compiled program only after
the provider reports a non-empty model artifact. Submit, refresh, and cancel
requests use stable idempotency keys and bounded retries. These lifecycle APIs
do not imply that an account-specific paid training job has run. From a source
checkout, the source-checkout-only `mix protocol.training.check` gate exercises the provider wire contracts
locally.

Fast-Slow Training has a separate provider-neutral orchestration surface. Build
immutable configuration and state with `DSEx.Training.FastSlow.Config` and
`State`, then execute paper-ordered cycles through
`DSEx.Training.FastSlow.Runner` and a module implementing
`DSEx.Training.FastSlow.Backend`. Each cycle prefetches exactly `T` minibatches,
runs the GEPA fast phase once, allocates exactly `G / K` rollouts to each of the
`K` retained prompts per question, and keeps that population fixed through the
`T` slow updates.

The checkpoint callback receives `%{state: state, runner_context: context}`.
Persist `state` with `DSEx.Training.FastSlow.Checkpoint` and persist the supplied
context map alongside it; `Runner.load_context!/2` verifies the actual
minibatch content digests against the state's lookahead. Backend context must be
credential-free, JSON-safe data. A backend must return `true` from
`replay_safe?/2` only after proving the provider effect is idempotent under the
operation intent or that the earlier attempt was not applied. Otherwise resume
fails with `:ambiguous_external_outcome` instead of duplicating a rollout or
weight update.

The shared `DSEx.Clients.Trainer` reinforcement boundary accepts the resulting
token-aligned trajectories, including behavior-policy token log probabilities,
response token IDs and masks, reward, and normalized advantage. The runner is a
paper-faithful BEAM orchestration adaptation; it is not a bundled weight trainer
and does not by itself establish paid-provider CISPO effectiveness.

### Run Training

Training optimizers are intentionally separate from program optimizers. Execute
`BootstrapFinetune` and `GRPO` with `DSEx.train/3` or `DSEx.train/4`, not
`DSEx.optimize`:

```elixir
trainer = MyApp.training_backend()
optimizer = DSEx.Optimizer.BootstrapFinetune.new(metric, trainer: trainer)

{:ok, training} = DSEx.train(program, optimizer, trainset)
```

`DSEx.train/3` and `DSEx.train/4` return
`{:ok, %DSEx.Optimizer.TrainingResult{}}` or
`{:error, reason}`. Bootstrap fine-tuning reports `status: :job_created` with its
provider job; GRPO reports `status: :completed` after its synchronous trainer
workflow returns the rebound program. Both require an explicitly configured
trainer. DSEx does not silently fall back to local training when no trainer is
configured. `DSEx.Clients.MLXLMTrainer` is an optional, explicit local SFT
backend, not a fallback. A training optimizer that declares optional validation
accepts it as `validation:` in the fourth-argument keyword options.

Optimizer-specific `compile` functions remain public for advanced workflows
that need their native return values or split/options layout. The MIPROv2 and
SIMBA checkpoint examples above use that direct surface. Constructor optimizers
such as `Ensemble` and `KNNFewShot`, and workflow optimizers such as `Playbook`,
also use their documented direct APIs; the `DSEx.optimize` facade accepts only
optimizers declaring `kind: :program`, while `DSEx.train` accepts only
`kind: :training`.

## Optimize Arbitrary Artifacts

The primary surface accepts a string, a named map of text components, or `nil`
for objective-driven seed generation. With no dataset it runs one evaluator
call per candidate. A `dataset:` selects multi-task optimization; adding a
non-empty `valset:` selects held-out generalization.

```elixir
alias DSEx.Optimize.Anything
alias DSEx.Optimize.Anything.{Config, Result}

config =
  Config.new(
    engine: [max_candidate_proposals: 4, max_metric_calls: 20],
    reflection: [reflection_lm: reflection_lm]
  )

result =
  Anything.optimize(
    %{planner: "Plan directly.", writer: "Answer clearly."},
    fn candidate, example ->
      score = evaluator.(candidate, example)
      {score, %{feedback: example.feedback, scores: %{quality: score}}}
    end,
    dataset: training_examples,
    valset: held_out_examples,
    objective: "Produce correct, concise answers.",
    config: config
  )

Result.best_candidate(result)
```

`Result` retains candidate lineage, per-example validation scores, Pareto
frontiers, measured budgets, rejected proposals, history, and a resumable
engine checkpoint. The older `new_artifact/3` API remains supported for callers
that need its aggregate evaluator and `Report` schema.

## GEPA-Style Reflection

DSEx's GEPA surface is an Elixir-native reflective optimizer over explicit
artifacts and evaluator functions. It borrows the GEPA ideas of per-example
scores, Actionable Side Information, Pareto selection, and candidate lineage;
it is not a wrapper around Python GEPA and should be cited with benchmark
evidence when making paper- or DSPy-comparison claims.

```elixir
artifact = DSEx.Optimize.Anything.new_artifact(:prompt, "Base")

report =
  DSEx.Optimize.GEPA.optimize(
    artifact,
    fn artifact, examples ->
      %{
        per_example_scores: Enum.map(examples, &if(String.contains?(artifact.text, &1), do: 1.0, else: 0.0)),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end,
    examples: ["Paris", "concise"],
    dev_examples: ["Paris"],
    generations: 2
  )

report.best
```

## Tools And ReAct

```elixir
{:ok, actions} =
  Agent.start_link(fn ->
    [
      %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
      %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
    ]
  end)

lm = %{
  module: DSEx.LM.Static,
  opts: [
    handler: fn _messages, _opts ->
      Agent.get_and_update(actions, fn
        [action | rest] -> {action, rest}
        [] -> {%{tool_calls: []}, []}
      end)
    end
  ]
}

lookup =
  DSEx.tool(
    :lookup,
    "lookup facts",
    fn %{query: "capital-france"} -> "Paris" end,
    schema: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  )

program = DSEx.react("question -> answer", [lookup], lm: lm, tool_policy: [:lookup, :submit])
{:ok, prediction} = DSEx.call(program, %{question: "What is the capital of France?"})
DSEx.get(prediction, :answer)
```

`ReAct` sends provider-style function definitions when the LM client supports
them. A reserved `submit` tool validates final outputs against the original
signature.

Use `DSEx.react_v2/3` when native multi-turn tool history and parallel calls are
required. ReActV2 preserves call/result IDs in `DSEx.History`, records unknown
and failing tools as observations instead of aborting, and forces one final
`submit` call when the normal loop ends. Existing `DSEx.react/3` retains its
fail-fast behavior. The pinned source mapping and deliberate DSEx policy/redaction
extensions are documented in `docs/REACT_V2_FIDELITY.md`.

### Tool Call Primitives

Use `DSEx.Adapters.Types.ToolCall` and `ToolCalls` when you need to inspect,
persist, or pass provider-native tool-call values outside a full ReAct loop.
They normalize DSEx maps and OpenAI-style nested function calls into the same
shape:

```elixir
calls =
  DSEx.Adapters.Types.ToolCalls.from_dict_list([
    %{id: "call_lookup", name: "lookup", arguments: %{query: "beam"}},
    %{id: "call_translate", function: %{name: "translate", arguments: ~s({"text":"hello"})}}
  ])

DSEx.Adapters.Types.ToolCalls.format(calls)
```

ReqLLM-backed assistant messages accept the same primitive values through the
ordinary `%{role: :assistant, tool_calls: calls}` message boundary, and provider
streaming exposes tool-call chunks as `%{tool_calls: [...]}` stream chunks.

## Agents

```elixir
tool = DSEx.tool(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

agent =
  DSEx.Agent.new(:doubler, fn agent, %{x: x}, runtime ->
    DSEx.Agent.call_tool(agent, :double, %{x: x}, runtime)
  end, tools: [tool], tool_policy: [:double])

{:ok, output, runtime} = DSEx.Agent.run(agent, %{x: 4})
```

For incremental traces:

```elixir
DSEx.Agent.stream_events(agent, %{x: 4}) |> Enum.to_list()
```

## MCP Import

```elixir
catalog =
  DSEx.MCP.Catalog.new([
    %{name: :lookup, description: "lookup", input_schema: %{required: [:key]}, run: & &1}
  ])

[tool] = DSEx.MCP.import_tools(catalog)
```

For HTTP-backed discovery, configure a real MCP endpoint. This is an external
service sketch, not a local runnable snippet:

```elixir
client = DSEx.MCP.HTTPClient.new("https://mcp.example/tools")
tools = DSEx.MCP.import_tools(client)
```

For stdio or Streamable HTTP transports, point DSEx at trusted services you own:

```elixir
stdio = DSEx.MCP.StdioClient.new("/path/to/server", args: ["--stdio"])
streamable = DSEx.MCP.StreamableHTTPClient.new("https://mcp.example/mcp", session_id: "session")
```

Only connect MCP stdio clients to trusted local executables. The stdio client
opens a process for discovery and opens a fresh process for each imported tool
call. DSEx treats MCP tools like ordinary `DSEx.Tool` values, so use tool
policies for anything with side effects.

## Advanced Protocol Clients

The normal provider path for inference is `DSEx.req_llm/2`. DSEx also ships
explicit protocol clients for application boundaries that are not ordinary LM
inference: HTTP retrievers, MCP transports, and provider training jobs. Those
clients are documented in [Advanced DSEx](ADVANCED.md) and
[Production Operations](PRODUCTION_OPERATIONS.md) because they require explicit
service ownership, credentials, payload contracts, and protocol-specific tests.

## RLM

RLM is DSEx's recursive language-model controller. It is not a synonym for RAG:
retrieval fetches context, while RLM runs a bounded loop that can assign state,
call tools, ask subquestions, recurse, and submit a final answer.

```elixir
lookup =
  DSEx.tool(:lookup, "lookup a fact", fn
    %{"key" => "priority"} -> "Prefer concise answers backed by evidence."
  end)

controller_lm = %{
  module: DSEx.LM.Static,
  opts: [
    handler: fn _messages, _opts ->
      %{
        reasoning: "The answer is already available in the task context.",
        code: ~S|submit(%{answer: "Prefer concise answers backed by evidence."})|
      }
    end
  ]
}

long_context = "priority: concise answers backed by evidence"

rlm =
  DSEx.rlm("context, question -> answer",
    lm: controller_lm,
    tools: [lookup],
    max_iterations: 20,
    max_llm_calls: 50,
    max_recursion_depth: 1,
    max_interpreter_value_bytes: 16_000_000,
    max_interpreter_effects: 100,
    max_time_ms: 30_000
  )

DSEx.call(rlm, %{context: long_context, question: "What matters?"})
```

The primary controller response contains reasoning and constrained Elixir code:

```elixir
%{
  reasoning: "Split the context and analyze each chunk semantically.",
  code: """
  context = load("large_context")
  chunks = String.split(context, "\n\n")
  findings = for chunk <- chunks, do: llm_query(chunk)
  submit(%{answer: Enum.join(findings, "\n")})
  """
}
```

Assignments persist across controller turns. The safe language includes data
literals, maps, lists, arithmetic and comparisons, `if`, bounded `for`
comprehensions, allowlisted `String`/`Enum` transformations, registered tools,
`llm_query/1`, `llm_query_batched/1`, `recurse/2`, `load/1`, `print/1`, and
`submit/1`. It cannot import modules, define functions, spawn processes, access
files or the network, or invoke arbitrary BEAM functions. Generated source is
never passed to `Code.eval_*`. Calls to LMs, tools, lazy loaders, and recursive
children are yielded as typed effects and executed by the RLM runtime, not by
the interpreter. Source, AST steps, generated value size, effect count, output,
recursion, sub-LM calls, and optional wall time are all bounded explicitly.

For large or expensive context, pass a lazy handle and let the controller load
it explicitly:

```elixir
context =
  DSEx.rlm_serializable(:large_context, fn ->
    File.read!("large-report.txt")
  end,
    metadata: %{source: "large-report.txt"}
  )

DSEx.call(rlm, %{large_context: context, question: "What changed?"})
```

The controller initially sees only metadata for the serializable value. The
`load/1` materializes it into the RLM variable space. `llm_query_batched/1`
runs sub-LM calls concurrently through supervised BEAM tasks, preserves result
order, and atomically reserves every item against the shared `max_llm_calls`
ledger. Recursive children use that same ledger and deadline. If controller
code submits malformed output, DSEx records
the parse feedback as an observation and gives the controller another turn. If
the loop exhausts its iteration budget, DSEx runs an extract pass over the
variables, observations, and trace to recover final structured output when
possible. A zero-iteration RLM still fails immediately without spending a
provider call.

## Save And Load

```elixir
program = DSEx.predict("question -> answer")

path = Path.join(System.tmp_dir!(), "dsex-program.json")
DSEx.save!(program, path)
loaded = DSEx.load!(path)
File.rm(path)
```

File artifacts use a versioned, checksummed envelope and atomic same-directory
replacement. Callback-bearing programs use trusted names:

```elixir
metric = fn _example, prediction -> DSEx.get(prediction, :answer, "") != "" end
registry = DSEx.Saving.Registry.new(quality_metric: metric)
program = DSEx.Predict.BestOfN.new(program, metric)

DSEx.save!(program, path, registry: registry)
loaded = DSEx.load!(path, registry: registry)
```

The deploying application must provide every referenced callback with the
expected arity. Unknown names and malformed or tampered artifacts fail before a
program is returned.

DSPy 3.3.0b1 has two persistence modes. `module.save("state.json")` plus
`module.load("state.json")` applies parameter state to an existing Python
program; the DSEx-native data boundary is `DSEx.dump/1` and `DSEx.load/1`, or
their checksummed file equivalents `DSEx.save!/2` and `DSEx.load!/1`. DSPy's
`module.save(path, save_program: true)` plus `dspy.load(path, allow_pickle:
true)` serializes executable Python with `cloudpickle`. DSEx intentionally has
no executable-code artifact mode: it saves allowlisted program architecture as
JSON, stores callback names through `DSEx.Saving.Registry`, and requires the
deploying application to rebind callbacks, tools, LMs, and credentials from
trusted runtime code.

Secrets are not persisted. Loaded HTTP LMs do not silently bind ambient
credentials. Rebind a freshly configured LM explicitly before live use:

```elixir
lm =
  DSEx.req_llm("openai:" <> System.fetch_env!("OPENAI_MODEL"),
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    temperature: 0
  )

loaded = DSEx.with_lm(loaded, lm)
DSEx.call(loaded, %{question: "What changed?"})
```

Portable saving supports the program types accepted by `DSEx.Saving`, including
compiled few-shot and ensemble graphs, callback wrappers, agents, and RAG
programs backed by `DSEx.memory/2`. External service clients remain host-owned.
Functions and tool closures must have stable names in a supplied registry; an
unregistered closure fails during dumping instead of entering the artifact.

## Streaming

```elixir
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = DSEx.predict("question -> answer", lm: lm)

DSEx.Streaming.stream(program, %{question: "q"}) |> Enum.to_list()

DSEx.Streaming.incremental_fields(
  ["[[ ## answer ## ]]Paris", "[[ ## rationale ## ]]lookup"],
  "question -> answer, rationale"
)
```

Provider streaming and delimiter-based field parsing are covered through
injectable transports and deterministic chunk fixtures.

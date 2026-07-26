# API Guide

This guide is organized around the things you build.

Most examples use the public `Imp` facade. Reach for deeper `Imp.*` modules
when you need direct control over adapters, optimizer reports, tools, agents, or
persistence. The canonical path is:

`signature -> program -> call -> evaluate -> optimize -> tools/agents -> operate`

## Configure An LM

For deterministic examples:

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

Imp.configure(lm: lm, adapter: Imp.Adapter.Chat)
```

Programs built without explicit `:lm` or `:adapter` resolve settings when they
are called, so a later `Imp.configure/1` or scoped `Imp.context/2` affects
existing programs. Pass `lm:` or `adapter:` to pin a program to a specific
runtime dependency.

Explicit `lm:` values are checked when the program is built. Imp accepts
`nil`, an LM module, an LM struct, a configured `%{module: module, opts:
keyword}` map, or an arity-2 callback. Explicit `adapter:` values accept `nil`
or a module exporting `format/3` and `parse/3`. Omit the option when you want
dynamic settings; pass the option when you want a self-contained program.

For production provider access, use the ReqLLM-backed client:

```elixir
model = System.fetch_env!("OPENAI_MODEL")
api_key = System.fetch_env!("OPENAI_API_KEY")

lm = Imp.req_llm("openai:#{model}", api_key: api_key, temperature: 0)
Imp.configure(lm: lm)
```

This delegates provider/model lookup, Req/Finch transport, streaming, and
provider option translation to the Elixir `req_llm` ecosystem. Imp still owns
the signature, adapter, optimizer, evaluation, and trace vocabulary.

For a runnable real-provider walkthrough, open
`livebooks/01_real_lm_front_door.livemd`. It is the best first stop after this
guide when you want the "this is actually an LM program" moment.

## Basic Predict

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program =
  "question -> answer: short_span"
  |> Imp.signature(
    "Answer with the shortest correct span. Do not explain."
  )
  |> Imp.predict(lm: lm)

{:ok, pred} = Imp.call(program, %{question: "Capital of France?"})
Imp.get(pred, :answer)
```

## Handle Failures

Program calls return tagged tuples. Match both branches at application
boundaries instead of assuming every provider call succeeds:

```elixir
require Logger

question = "What is the capital of France?"

case Imp.call(program, %{question: question}) do
  {:ok, prediction} ->
    {:ok, Imp.get(prediction, :answer)}

  {:error, reason} ->
    Logger.warning("Imp call failed", reason: inspect(reason))
    {:error, :language_model_unavailable}
end
```

Missing inputs, provider failures, malformed provider returns, and exhausted
adapter retries are returned as `{:error, reason}`. Invalid constructor options
and unsupported program shapes raise `ArgumentError` because they are local
configuration defects and should fail before serving traffic.

Evaluation keeps per-example failures visible rather than hiding them:

```elixir
devset = [
  Imp.example(question: "Eiffel Tower city?", answer: "Paris") |> Imp.with_inputs(:question)
]

metric = Imp.exact_match(:answer)

report = Imp.evaluate(program, devset, metric, failure_score: 0.0, max_errors: 5)

Enum.each(report.errors, fn error ->
  Logger.warning("Imp evaluation row failed", error: inspect(error))
end)
```

Use a finite `:max_errors` in production jobs to stop a systematically broken
campaign. Use `:infinity` only when collecting every failure is intentional.

## Conversation History

Use `Imp.history/1` when a signature should see prior task turns. History is
signature-shaped data, not provider chat logs: each turn is a field map with the
same input/output names the program already understands.

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Rome"} end]
}

program = Imp.predict("question, history -> answer", lm: lm)

history =
  Imp.history([
    %{question: "What is the capital of France?", answer: "Paris"},
    %{question: "What is the capital of Germany?", answer: "Berlin"}
  ])

{:ok, prediction} =
  Imp.call(program, %{question: "What is the capital of Italy?", history: history})

Imp.get(prediction, :answer)
```

The Chat adapter renders history turns before the current request, splitting
each turn into prior user/assistant messages according to the active signature.
`Imp.History.dump/1` and `Imp.History.load/1` give a JSON-safe boundary for
application state, while `Imp.History.redact/1` supports safe inspection.
Provider-native role messages remain explicit maps with role and content fields.

## The Canonical Path

Start with one typed program, evaluate it, attach examples, then optimize only
after the metric is meaningful:

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = Imp.predict("question -> answer", lm: lm)

trainset = [
  Imp.example(question: "Capital of France?", answer: "Paris")
  |> Imp.with_inputs(:question)
]

devset = [
  Imp.example(question: "Eiffel Tower city?", answer: "Paris")
  |> Imp.with_inputs(:question)
]

metric = Imp.exact_match(:answer)

baseline = Imp.evaluate(program, devset, metric)

compiled =
  program
  |> Imp.optimize!(
    Imp.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1),
    trainset,
    devset
  )

{baseline.score, Imp.Optimizer.Report.fetch(compiled)}
```

Use deeper modules such as `Imp.Evaluate` or `Imp.Optimizer.RandomSearch`
directly when you need to hold evaluator structs, inspect optimizer internals,
or build custom orchestration. `Imp.Evaluate.new/3` accepts
`max_concurrency:` for bounded parallel row evaluation while preserving row
order, process-local settings, feedback, metric metadata, and error budgeting.

## Which Program Shape?

| Use this | When |
| --- | --- |
| `Imp.predict/2` | One model call maps named inputs to named outputs. |
| `Imp.chain_of_thought/2` | You want a reasoning field before the final answer. |
| `Imp.multi_chain_comparison/2` | You already have candidate completions and want a self-consistency chooser. |
| `Imp.best_of_n/3` | You want to run one program several times and keep the highest-scored result. |
| `Imp.refine/3` | You want bounded retry with feedback until a metric passes. |
| `Imp.assert/3` | You want named runtime constraints to produce feedback and self-repair attempts. |
| `Imp.parallel/3` | You want supervised concurrent batch calls with one result per input. |
| `Imp.knn/3`, `Imp.nearest/2` | You want nearest-neighbor examples from a local trainset. |
| `Imp.react/3` | The model should choose tools and then submit a validated answer. |
| `Imp.react_v2/3` | You need native parallel tool calls with truthful IDs in history, and failed tools recorded as observations instead of aborts. |
| `Imp.avatar/3` | You want one typed action per turn, with each tool isolated under its own timeout. |
| `Imp.program_of_thought/2` | The model should write small sandboxed Elixir snippets. |
| `Imp.code_act/3` | You want interleaved tool/code execution under a policy. |
| `Imp.rlm/2` | You need a bounded recursive controller for large-context exploration. |

The later sections are there when your program needs more control, not because
every Imp project should start with agents or recursive controllers.

## Composition Helpers

```elixir
lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
program = Imp.predict("question -> answer", lm: lm)
metric = Imp.exact_match(:answer)

{:ok, best} =
  program
  |> Imp.best_of_n(metric, n: 2)
  |> Imp.call(%{question: "2+2?"})

{:ok, refined} =
  program
  |> Imp.refine(metric, max_attempts: 1)
  |> Imp.call(%{question: "sqrt 16?"})

batch =
  Imp.parallel(program, [%{question: "2+2?"}, %{question: "sqrt 16?"}],
    max_concurrency: 2
  )

{Imp.get(best, :answer), Imp.get(refined, :answer), length(batch)}
```

Use assertion-guided refinement when the constraint is clearer than a full task
metric:

```elixir
one_word =
  Imp.assertion(:one_word, fn prediction ->
    prediction
    |> Imp.get(:answer, "")
    |> to_string()
    |> String.split()
    |> length() == 1
  end, message: "Answer with one word.")

{:ok, constrained} =
  program
  |> Imp.assert(one_word, max_attempts: 2)
  |> Imp.call(%{question: "Capital of France?"})

{Imp.get(constrained, :answer), Imp.get(constrained, :assertion_score)}
```

For self-consistency workflows — run a program several times, keep the most
common answer — `Imp.majority/2` votes on a field across predictions.
Values are trimmed and downcased before grouping (pass `normalize:` for a
custom grouping function), and ties keep the first value from the winning
group:

```elixir
predictions = [
  Imp.prediction(answer: "4"),
  Imp.prediction(answer: " 4"),
  Imp.prediction(answer: "5")
]

Imp.majority(predictions, field: :answer)
#=> "4"
```

`Imp.multi_chain_comparison/2` is useful when candidate completions are
already available. The comparison step adds a required `rationale` output to
the signature, so the model (scripted here) must return that field too:

```elixir
mcc_lm = %{
  module: Imp.LM.Static,
  opts: [
    handler: fn _messages, _opts ->
      %{rationale: "both candidates compute 2+2 directly", answer: "4"}
    end
  ]
}

chooser = Imp.multi_chain_comparison("question -> answer", lm: mcc_lm, m: 2)

Imp.call(chooser, %{
  question: "2+2?",
  completions: [
    %{reasoning: "addition", answer: "4"},
    %{reasoning: "counting", answer: "4"}
  ]
})
```

`Imp.knn/3` builds an embedding-based nearest-neighbor predictor over examples
(the DSPy `KNN` port: the trainset embeds once through the required
`:vectorizer`, queries score by dot product). It returns retrieved examples
rather than a model prediction:

```elixir
trainset = [
  Imp.example(question: "capital France", answer: "Paris") |> Imp.with_inputs(:question)
]

knn = Imp.knn(1, trainset, vectorizer: Imp.Embeddings.BagOfWords)
Imp.nearest(knn, %{question: "France"})
```

## Request-Local Inference Search

Use `Imp.best_of_n/3` for bounded candidate evaluation and `Imp.refine/3` for
feedback-guided retries. Both keep candidate state, projected budgets,
provenance, threshold stopping, and failure isolation within one request. They
do not register a process or persist search state. The facade returns the
highest-scoring successful prediction using deterministic tie handling, and
reports projected accounting separately from provider billing.

Sequential retries preserve ordered history for feedback. Concurrent batches
are supervised and bounded by `max_concurrency`; speculative work that already
completed remains visible in the result. Record actual provider usage through
the provider or telemetry boundary rather than treating projected budgets as
measured usage.

## Chain Of Thought

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{reasoning: "add two and two", answer: "4"} end]
}

Imp.configure(lm: lm, adapter: Imp.Adapter.Chat)

program = Imp.chain_of_thought("question -> answer")
{:ok, pred} = Imp.call(program, %{question: "2+2?"})

Imp.get(pred, :reasoning)
Imp.get(pred, :answer)
```

Manual reasoning fields are ordinary signature outputs. Provider-native
reasoning is separate: ReqLLM-backed providers can return thinking/reasoning
tokens, and Imp preserves them in prediction metadata without pretending they
are a declared output field:

```elixir
{:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})

prediction.metadata[:native_reasoning]
prediction.metadata[:reasoning_details]
```

Streaming provider-native thinking chunks arrive as `%{reasoning: text}` chunks
with `metadata.type == :reasoning`; ordinary answer text still streams as text.
Outbound reasoning values become ReqLLM thinking content parts for providers
that support reasoning continuity.

## Schema-Constrained JSON

```elixir
signature =
  Imp.signature(%{
    inputs: [:text],
    outputs: [
      %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })

program = Imp.predict(signature, adapter: Imp.Adapter.JSON)
```

The JSON adapter validates output fields and returns retry feedback for schema
violations.

Answer-shape constraints are useful for extractive tasks:

```elixir
signature =
  Imp.signature(
    "question -> verdict: yes_no, amount: numeric_span, answer: short_span",
    "Extract only the requested answer fields."
  )
```

## Streaming

`Imp.stream/3` returns an Enumerable of chunks from one program
call, and `Imp.collect/3` joins a stream back into a string —
returning `{:error, reason}` rather than partial output if any chunk fails.

With a ReqLLM-backed LM and `provider_stream: true`, chunks arrive from the
provider as it generates: answer text as strings, provider-native thinking as
`%{reasoning: text}` chunks tagged `metadata.type == :reasoning`, and tool
calls as `%{tool_calls: [...]}` chunks (see Chain Of Thought above).

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))
program = Imp.predict("question -> answer", lm: lm)

program
|> Imp.stream(%{question: "Name the Galilean moons."}, provider_stream: true)
|> Enum.each(&IO.write(if is_binary(&1), do: &1, else: ""))
```

In a LiveView, run the stream in a supervised task and send chunks to the
view — a sketch of the shape:

```elixir
def handle_event("ask", %{"q" => q}, socket) do
  view = self()

  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    MyApp.Router.program()
    |> Imp.stream(%{question: q}, provider_stream: true)
    |> Enum.each(&send(view, {:answer_chunk, &1}))

    send(view, :answer_done)
  end)

  {:noreply, assign(socket, answer: "")}
end

def handle_info({:answer_chunk, text}, socket) when is_binary(text) do
  {:noreply, update(socket, :answer, &(&1 <> text))}
end
```

Programs that cannot provider-stream (and any program without
`provider_stream: true`) degrade honestly: the call runs once and the result
is chunked locally, so stream consumers keep working. That is also the
testing story — a scripted model streams through the same interface:

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = Imp.predict("question -> answer", lm: lm)

Imp.stream(program, %{question: "q"}) |> Enum.to_list()
#=> ["P", "a", "r", "i", "s"]
```

Pass `chunker: fn text -> [...] end` to control local chunking.
`Imp.Streaming.incremental_fields/2` is the lower-level parser that turns
delimiter-marked chunk sequences into per-field increments:

```elixir
Imp.Streaming.incremental_fields(
  ["[[ ## answer ## ]]Paris", "[[ ## rationale ## ]]lookup"],
  "question -> answer, rationale"
)
#=> [%{field: :answer, value: "Paris"}, %{field: :rationale, value: "lookup"}]
```

## Examples And Demos

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "4"} end]
}

demo =
  Imp.example(question: "2+2?", answer: "4")
  |> Imp.with_inputs(:question)

program =
  "question -> answer"
  |> Imp.predict(lm: lm)
  |> Imp.with_demos([demo])
```

## Evaluate A Program

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = Imp.predict("question -> answer", lm: lm)

devset = [
  Imp.example(question: "Capital of France?", answer: "Paris") |> Imp.with_inputs(:question)
]

metric = Imp.exact_match(:answer)
report = Imp.evaluate(program, devset, metric)
report.score
```

Metrics may return booleans, numbers, maps with `:score` / `:feedback`, or a
`Imp.Prediction` carrying score and feedback. Imp normalizes those returns
into row scores, pass/fail state, feedback, and metric metadata. Arity-3 metrics
receive the prediction trace as their third argument.

Built-in metric helpers cover common benchmark shapes:

```elixir
qa = Imp.extractive_qa("since 2000", "2000")

report =
  Imp.classification_report([
    {"warm", "warm"},
    {"warm", "cool"},
    {"cool", "cool"}
  ])

{qa.metadata["f1"], report["macro_f1"]}
```

## Retrieval-Augmented Programs

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

docs = [
  %{text: "France has capital Paris."},
  %{text: "Germany has capital Berlin."}
]

retriever = Imp.memory(docs, k: 1)

program =
  "question, context -> answer"
  |> Imp.predict()
  |> Imp.rag(retriever, k: 1)

{:ok, prediction} =
  Imp.context([lm: lm], fn ->
    Imp.call(program, %{question: "capital France"})
  end)

Imp.get(prediction, :answer)
prediction.metadata.retrieval
```

`Imp.rag/3` is intentionally small: it retrieves documents, renders them into
the configured context field, calls the wrapped program, and records retrieval
metadata. The wrapped program can be a plain `Predict`, a compiled few-shot
program, or any other callable Imp module that expects a context input. For
multi-hop retrieval, pass `hops: 2` or higher; each hop expands the original
query with previously retrieved passages, deduplicates documents, injects the
combined context, and records per-hop retrieval metadata.
RAG programs backed by `Imp.memory/2` can be saved and loaded with
`Imp.dump/1`, `Imp.load/1`, `Imp.save!/2`, and `Imp.load!/1`; network
retrievers remain host-owned dependencies. Callback-bearing program graphs are
persisted through a named `Imp.Saving.Registry` supplied explicitly by the
host; functions are never written into artifacts.

## Local Embeddings

```elixir
{:ok, vectors} =
  Imp.Embeddings.embed(
    Imp.Embeddings.BagOfWords,
    ["elixir language model programs", "python prompt scripts"],
    dims: 8
  )

length(hd(vectors))
```

`Imp.Embeddings.BagOfWords` is deterministic and local. It is useful for
examples, tests, and small retrieval experiments. Production semantic embeddings
should be injected behind the `Imp.Embeddings` behaviour so credentials,
network calls, and model choice stay explicit. Any provider must return exactly
one numeric vector for each input text, in the same order.

## Datasets

`Imp.Datasets` turns records you already have into example lists: 
`from_records/3` for in-memory data, `jsonl/3` and `csv/3` for files, and
`split/2` for a shuffled train/dev split. Benchmark-shaped loaders —
`Imp.Datasets.GSM8K`, `HotPotQA`, `MATH`, `Colors` — read files in those
datasets' formats from paths you supply; nothing is downloaded for you.

```elixir
examples =
  Imp.Datasets.from_records(
    [%{question: "Capital of France?", answer: "Paris"}],
    [:question]
  )
```

Every loader returns `Imp.Example` values with inputs already marked, ready
for `Imp.evaluate/4` and the optimizers. `Imp.Datasets.GSM8K.metric/3` is the
benchmark metric: it compares the canonical final answer (the `#### N` value,
kept in `:canonical_answer` by the fetcher) with numeric equivalence and a
normalized text fallback, mirroring DSPy's `gsm8k_metric`, so a prediction of
`"18"` scores true against a gold rationale ending `#### 18`.

## Optimize A Program

```elixir
lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = Imp.predict("question -> answer", lm: lm)

trainset = [
  Imp.example(question: "Capital of France?", answer: "Paris") |> Imp.with_inputs(:question)
]

devset = [
  Imp.example(question: "Eiffel Tower city?", answer: "Paris") |> Imp.with_inputs(:question)
]

metric = Imp.exact_match(:answer)
optimizer = Imp.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
compiled = Imp.optimize!(program, optimizer, trainset, devset)

Imp.Optimizer.Report.fetch(compiled)
```

The facade dispatches through the `Imp.Optimizer` behaviour. Each optimizer
implements `__optimizer__/0` and `run/3`; `Imp.optimizer_capabilities/1`
returns its validated declaration:

- `kind` is `:program`, `:training`, `:constructor`, or `:workflow`.
- `datasets` maps named splits such as `trainset`, `validation`,
  `promotionset`, and `auditset` to `:required`, `:optional`, or
  `:unsupported`.
- `result` declares the expected result shape; workflows name their concrete
  result module.

Use `Imp.optimize!/3` when a program optimizer does not require validation,
`Imp.optimize!/4` when supplying validation, and `Imp.optimize!/5` when also
passing invocation options such as checkpoint controls. This choice follows the
declared split requirements; Imp does not infer argument meaning from an
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
| `GEPA` | You want reflective instruction evolution, where the optimizer reads text feedback from your metric and rewrites instructions between candidates. |
| `Avatar` / `AvatarOptimizer` | You want bounded typed tool use and feedback-driven actor-instruction optimization from positive and negative trajectories. |
| `BetterTogether` | You want named prompt/weight optimizers applied in a configurable sequence, with every successful prefix evaluated and the best validation candidate retained. |

`LabeledFewShot.new/1` follows DSPy 3.2.1's user-visible defaults: `k: 16`,
deterministic sampling without replacement, and seed zero. Use `sample: false`
for the ordered first-`k` path, or set `seed:` for another reproducible BEAM
sample. Imp carries this as explicit serializable optimizer RNG state; equal
integer seeds are not promised to reproduce Python's incidental subset order.

`InferRules` is rule induction, not a renamed instruction search. Give it a
separate rule LM when you want the task program and optimizer to use different
models:

```elixir
rule_lm =
  Imp.req_llm("openai:" <> System.fetch_env!("OPENAI_RULE_MODEL"),
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    temperature: 1.0
  )

infer_rules =
  Imp.Optimizer.InferRules.new(metric,
    rule_lm: rule_lm,
    num_candidates: 4,
    num_rules: 6,
    max_bootstrapped_demos: 2
  )

compiled = Imp.optimize!(program, infer_rules, trainset, devset)
```

Each candidate sees the observed input and output values for each predictor,
not merely the field names. The selected program carries its induced rules and
an `:infer_rules` optimizer report. Imp also evaluates the bootstrapped baseline
and retains it when every induced candidate regresses. For deterministic replay,
pass already-induced rule strings with `candidates: [...]`; this bypasses rule-LM
calls but still performs validation selection.

When the rule LM returns a structured `Imp.ContextWindowExceededError`,
InferRules retries after dropping one trailing training example at a time, as
DSPy 3.2.1 does. The report distinguishes logical `proposal_calls` from actual
`proposal_attempts`. If even one example does not fit, Imp records that proposal
error and keeps searching—or returns the evaluated baseline—instead of aborting
the entire compile as upstream does. Retry attempts reuse the logical proposal's
sequential rollout ID while the prompt changes; DSPy draws a fresh random
rollout ID on each attempt.

For a manually sized MIPROv2 run, configure the canonical `Config` options and
the runtime `startup_trials` setting explicitly:

```elixir
mipro =
  Imp.Optimizer.MIPROv2.new(metric,
    auto: nil,
    num_candidates: 4,
    num_trials: 8,
    max_bootstrapped_demos: 2,
    max_labeled_demos: 2,
    minibatch: false,
    startup_trials: 2
  )
```

`minibatch: false` matters at this scale: minibatched evaluation is the
default, and its `minibatch_size` must not exceed the validation-set size, so
a small `devset` like the one on this page rejects the run before it starts.

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
  Imp.Optimizer.MIPROv2.compile(mipro, program, trainset, devset,
    max_trials: 2,
    checkpoint_fn: persist
  )

checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()

resumed =
  Imp.Optimizer.MIPROv2.compile(mipro, program, trainset, devset,
    resume_state: checkpoint,
    checkpoint_fn: persist
  )
```

For SIMBA, build the optimizer, then use the corresponding five-argument call
and invocation-level `max_steps:` option:

```elixir
simba = Imp.Optimizer.SIMBA.new(metric, bsize: 1, num_candidates: 2, max_steps: 1)

Imp.Optimizer.SIMBA.compile(simba, program, trainset, devset,
  max_steps: 1,
  checkpoint_fn: persist
)
```

Reports expose `metadata.run_status` as `:paused` or `:complete`. Which
boundaries replay, the rebinding and trust contract, and the provider
training-job lifecycle are in [Operations Reference](OPERATIONS_REFERENCE.md).

Build an Avatar through the facade, then optimize its actor instruction with
the dedicated optimizer:

```elixir
lookup_country = fn
  %{country: "France"} -> "Paris"
  _other -> "unknown"
end

actor_lm = %{
  module: Imp.LM.Static,
  opts: [
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)

      cond do
        prompt =~ "Do not request another tool." ->
          if prompt =~ "Paris", do: %{answer: "Paris"}, else: %{answer: "unknown"}

        prompt =~ "tool_output:" ->
          %{action: %{tool_name: "Finish", tool_input_query: %{}}}

        true ->
          %{action: %{tool_name: "lookup", tool_input_query: %{country: "France"}}}
      end
    end
  ]
}

feedback_lm = %{
  module: Imp.LM.Static,
  opts: [handler: fn _messages, _opts -> %{feedback: "Use exact country names."} end]
}

rewrite_lm = %{
  module: Imp.LM.Static,
  opts: [
    handler: fn _messages, _opts ->
      %{new_instruction: "Look up the exact country name, then Finish."}
    end
  ]
}

lookup = Imp.tool(:lookup, "Look up a country capital", lookup_country)
avatar = Imp.avatar("question -> answer", [lookup], lm: actor_lm, max_iters: 3)

avatar_optimizer =
  Imp.Optimizer.Avatar.new(Imp.exact_match(:answer),
    comparator_lm: feedback_lm,
    rewrite_lm: rewrite_lm,
    max_iters: 2
  )

compiled_avatar = Imp.optimize!(avatar, avatar_optimizer, trainset)
```

Avatar records typed action observations, treats unknown, denied, and failed
tool calls as recoverable observations, and invokes a typed finalizer on
`Finish` or iteration exhaustion. AvatarOptimizer keeps a rewritten instruction
only when its trainset score improves. BetterTogether accepts named optimizers
and atom, string, or repeated list strategies; with validation it retains the
highest-scoring baseline/prefix candidate, and without validation it returns
the latest successful prefix. A typed asynchronous `TrainingJob` is polled
under the configured deadline, rebound only after terminal success, and given a
bounded cancellation attempt after timeout or refresh failure.

When no validation set is supplied, the positive `valset_ratio` default keeps
at least one validation row from trainsets of two or more examples. This makes
small-dataset prefix selection real instead of silently becoming the
no-validation/latest-prefix path. A single example remains a training row; pass
an explicit validation set when selection is required at that size.

To continue a `BetterTogether` workflow from an already-completed weight job,
use the explicit adoption optimizer. Adoption verifies and binds the exact job,
artifact contents, incoming program, and base-model identity; it performs no
trainer dispatch, fusion, or weight update.

```elixir
job = Imp.Clients.TrainingJob.load!("training-job.json")

weight_step =
  Imp.Optimizer.TrainingJobAdoption.new(job, base_program)

optimizer =
  Imp.Optimizer.BetterTogether.new(metric, %{
    w: weight_step,
    p: Imp.Optimizer.COPRO.new(metric, proposer_lm: proposer_lm)
  })

program =
  Imp.Optimizer.BetterTogether.compile(
    optimizer,
    base_program,
    trainset,
    validation_set,
    strategy: [:w, :p]
  )
```

Top-level `max_errors:` and `max_concurrency:` belong to BetterTogether's
baseline and prefix-selection evaluation. Put child optimizer controls under
`optimizer_compile_args:`. COPRO's internal trainset evaluation, for example,
uses its public `num_threads:` and `max_errors:` compile options:

```elixir
Imp.Optimizer.BetterTogether.compile(
  optimizer,
  base_program,
  trainset,
  validation_set,
  strategy: [:w, :p],
  max_concurrency: 1,
  max_errors: :infinity,
  optimizer_compile_args: %{p: [num_threads: 1, max_errors: :infinity]}
)
```

BetterTogether validates declared child options before evaluating the baseline.
Unknown COPRO options fail loudly and no child option is silently dropped.

`TrainingJobAdoption` declares the training-result protocol only because
`BetterTogether` uses that protocol for weight-bearing steps. Its result
metadata records `training_performed: false`; it accepts only supported,
content-verified completed artifacts and fails closed on job, artifact, base,
or program drift.

Optimizers that use an LM for proposal or reflection, such as COPRO, SIMBA,
and GEPA-style artifact optimization, use the same explicit LM shapes as
programs. `proposer_lm:`, `prompt_lm:`, and `reflection_lm:` reject malformed
values when the optimizer is built or run, before a search loop starts.

Optimizer-specific `compile` functions remain public for advanced workflows
that need their native return values or split/options layout. The MIPROv2 and
SIMBA checkpoint examples above use that direct surface. Constructor optimizers
such as `Ensemble` and `KNNFewShot`, and workflow optimizers such as `Playbook`,
also use their documented direct APIs; the `Imp.optimize` facade accepts only
optimizers declaring `kind: :program`, while `Imp.train` accepts only
`kind: :training`.

Training optimizers (`BootstrapFinetune`, `GRPO`), Fast-Slow training, and
provider dispatch journals live in
[Operations Reference](OPERATIONS_REFERENCE.md). Whether any optimizer here has
been proven effective, and to what rung, is recorded in [Evidence](EVIDENCE.md).

## Optimize Arbitrary Artifacts

The primary surface accepts a string, a named map of text components, a
JSON-safe structured map, or `nil` for objective-driven seed generation. With
no dataset it runs one evaluator call per candidate. A `dataset:` supplies
proposal/reflection examples; adding a non-empty `valset:` supplies separate
examples for candidate selection. The validation set is not an untouched test
set: measure the selected candidate on different examples after optimization.

```elixir
evaluator = fn candidate, _example ->
  if candidate.planner =~ "numbered steps", do: 1.0, else: 0.5
end

training_examples = [
  %{feedback: "The plan needs explicit numbered steps."},
  %{feedback: "Number each step of the plan."}
]

validation_examples = [%{feedback: "Validation: numbered steps still required."}]
test_examples = [%{feedback: "Test: the plan still needs numbered steps."}]

reflection_lm =
  Imp.LM.Static.new(
    handler: fn _messages, _opts -> "Plan with explicit numbered steps." end
  )

result =
  Imp.Optimize.Anything.run(
    %{planner: "Plan directly.", writer: "Answer clearly."},
    fn candidate, example ->
      score = evaluator.(candidate, example)
      {score, %{feedback: example.feedback, scores: %{quality: score}}}
    end,
    dataset: training_examples,
    valset: validation_examples,
    objective: "Produce correct, concise answers.",
    config: [
      engine: [max_candidate_proposals: 4, max_metric_calls: 20],
      reflection: [reflection_lm: reflection_lm]
    ]
  )

best_candidate = Imp.Optimize.Anything.best_candidate(result)
test_scores = Enum.map(test_examples, &evaluator.(best_candidate, &1))
```

The result retains candidate lineage, per-example validation scores, Pareto
frontiers, measured budgets, rejected proposals, history, and a resumable
engine checkpoint. `test_scores` is the only untouched outcome in this example;
the optimizer has seen both `training_examples` and validation scores.
`Imp.Optimize.Anything.run/3` is the sole Optimize Anything execution
entry point; `best_candidate/1` reads its selected artifact while execution
records remain implementation data rather than additional supported module
APIs.

Pinned GEPA v0.1.4 defines candidates as `str | dict[str, str]`. Imp additionally
supports typed structured maps with seed-derived exact keys, list lengths, and
value types. Evaluators and proposers see the native artifact, not its internal
checkpoint encoding. Invalid JSON, missing fields, type drift, and no-op
proposals are rejected. Refiner, merge, external tracking, custom callbacks,
and custom selectors remain text-only and are rejected up front in structured
mode rather than receiving an encoded substitute. The `__imp_type__` key is
reserved at every depth for Imp's durable wire tags.

Pinned GEPA v0.1.4's grouped evaluator surface is available through the same
entry point: pass `nil` as the scalar evaluator and an arity-one
`batch_evaluator:` receiving ordered `{candidate, example}` pairs, or use
arity two to also receive aligned optimization states. One result is required
per pair. The batch callback sees unwrapped string candidates, `nil` examples
in single-task mode, and native structured artifacts. When both evaluator
forms are present, grouped stages prefer the batch callback. Legacy
three-tuples cannot substitute their output for the evaluated candidate.
Contained per-row and whole-call failures remain aligned for diagnostics, but
incomplete proposals are not cached, selected, or installed as winners.

`reflection.batch_sampler` accepts `:epoch_shuffled` or a stateful struct that
implements `Imp.Optimizer.GEPA.BatchSampler`. A custom strategy owns its
minibatch size, so it cannot be combined with `reflection_minibatch_size`. Its
callback receives the native training examples plus iteration/call context,
and returns ordered zero-based indexes, updated strategy state, and RNG state.
Imp checkpoints the strategy module, stable identity, and dumped state; resume
requires the same strategy identity and restores it before another evaluator
call. Runtime strategy structs intentionally make the nested config
non-persistable, while the optimization checkpoint remains JSON-resumable.

Multi-proposal controls are also engine settings on the nested public config.
`sampling_strategy` accepts `:single`, `{:same_parent, n}`,
`{:independent, n}`, or `{:pxn, parents, mutations}`. `selection_strategy`
accepts `:all_improvements`, `:best_improvement`, `{:top_k, n}`, or the
documented BEAM callback form. `acceptance_criterion` accepts
`:strict_improvement`, pinned-name `:improvement_or_equal`, native alias
`:equal_or_better`, or `Imp.Optimizer.GEPA.Acceptance.callback/1`. These values
control the real proposal batch, filtering, and admission decisions and are
bound into resumable checkpoints; changing any of them on resume fails before
evaluation. Unsupported Python strategy objects are rejected by config
construction rather than accepted and ignored. `max_candidate_proposals`
counts proposal rounds as it does upstream; it no longer doubles as a
reflection-call cap when one round contains multiple proposals.

Pinned Optimize Anything returns an immutable result rather than mutating an
application object, and Imp preserves that boundary. Install
`best_candidate/1` explicitly into the consumer program/configuration and then
run that value; there is no accepted-but-ignored application callback. This
keeps selection auditable and allows the selected native structured artifact
to cross into a fresh BEAM process without an internal text wrapper.

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
  module: Imp.LM.Static,
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
  Imp.tool(
    :lookup,
    "lookup facts",
    fn %{query: "capital-france"} -> "Paris" end,
    schema: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  )

program = Imp.react("question -> answer", [lookup], lm: lm, tool_policy: [:lookup, :submit])
{:ok, prediction} = Imp.call(program, %{question: "What is the capital of France?"})
Imp.get(prediction, :answer)
```

`ReAct` sends provider-style function definitions when the LM client supports
them. A reserved `submit` tool validates final outputs against the original
signature.

Use `Imp.react_v2/3` when native multi-turn tool history and parallel calls are
required. ReActV2 preserves call/result IDs in `Imp.History`, records unknown
and failing tools as observations instead of aborting, and forces one final
`submit` call when the normal loop ends. Existing `Imp.react/3` retains its
fail-fast behavior.

### Tool Call Primitives

Use `Imp.Adapter.Types.ToolCall` and `ToolCalls` when you need to inspect,
persist, or pass provider-native tool-call values outside a full ReAct loop.
They normalize Imp maps and OpenAI-style nested function calls into the same
shape:

```elixir
calls =
  Imp.Adapter.Types.ToolCalls.from_dict_list([
    %{id: "call_lookup", name: "lookup", arguments: %{query: "beam"}},
    %{id: "call_translate", function: %{name: "translate", arguments: ~s({"text":"hello"})}}
  ])

Imp.Adapter.Types.ToolCalls.format(calls)
```

ReqLLM-backed assistant messages accept the same primitive values through the
ordinary `%{role: :assistant, tool_calls: calls}` message boundary, and provider
streaming exposes tool-call chunks as `%{tool_calls: [...]}` stream chunks.

## Agents

Imp has several action patterns because agents fail in several ways, and each
pattern buys a different safety trade. `Imp.react/3` is the upstream-shaped
tool loop: provider tool calls, a reserved `submit` that validates the final
answer, fail-fast on unknown tools. `Imp.react_v2/3` is the native-calling
loop: parallel tool calls keep their IDs in history, unknown or failing tools
become observations instead of aborting the run, and a final `submit` is
forced if the loop ends without output. `Imp.avatar/3` takes one typed action
per turn and runs each tool in an isolated task under `:tool_timeout_ms`, so
one hung tool cannot hang the run. `Imp.code_act/3` and
`Imp.program_of_thought/2` move the action into sandboxed Elixir code, and
`Imp.rlm/2` gives a controller model a budgeted recursive sandbox. Start with
`react/3`; move along the spectrum when a failure mode demands it.

The packaged surface deliberately stops there. When you want to own the loop
yourself, compose the same pieces in ordinary Elixir: call `Imp.Tool.call/2`
from your own process, keep the loop's state in a GenServer you supervise,
and pass a `tool_policy:` to any react-family program you delegate to. An
agent loop you wrote is an agent loop you can reason about — that is the BEAM
story, not a resident framework.

```elixir
double = Imp.tool(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

Imp.Tool.call(double, %{x: 4})
#=> %{y: 8}
```

## MCP Import

Tool schemas use the MCP specification dialect: the input contract key is
camelCase `"inputSchema"` and `"description"` is optional. In-process Elixir
catalogs may also use the snake_case `:input_schema` spelling as a back-compat
fallback; real MCP servers always send `inputSchema`.

```elixir
catalog =
  Imp.MCP.Catalog.new([
    %{"name" => "lookup", "inputSchema" => %{"required" => ["key"]}, "run" => & &1}
  ])

[tool] = Imp.MCP.import_tools(catalog)
```

For HTTP-backed discovery, configure a real MCP endpoint. This is an external
service sketch, not a local runnable snippet:

```elixir
client = Imp.MCP.HTTPClient.new("https://mcp.example/tools")
tools = Imp.MCP.import_tools(client)
```

Imp treats MCP tools like ordinary `Imp.Tool` values, so use tool policies for
anything with side effects. Stdio and Streamable HTTP transports are covered in
[Operations Reference](OPERATIONS_REFERENCE.md).

## Advanced Protocol Clients

The normal provider path for inference is `Imp.req_llm/2`. Imp also ships
explicit protocol clients for application boundaries that are not ordinary LM
inference: HTTP retrievers, MCP transports, and provider training jobs. Those
clients are documented in [Advanced Imp](ADVANCED.md) and
[Operations Reference](OPERATIONS_REFERENCE.md) because they require explicit
service ownership, credentials, payload contracts, and protocol-specific tests.

When a collection of independent provider calls must survive process or host
restarts, `Imp.Clients.ReqLLMBatch` runs them against a resumable checkpoint;
[Operations Reference](OPERATIONS_REFERENCE.md) covers the batch API.

## RLM

RLM is Imp's recursive language-model controller. It is not a synonym for RAG:
retrieval fetches context, while RLM runs a bounded loop that can assign state,
call tools, ask subquestions, recurse, and submit a final answer.

```elixir
lookup =
  Imp.tool(:lookup, "lookup a fact", fn
    %{"key" => "priority"} -> "Prefer concise answers backed by evidence."
  end)

controller_lm = %{
  module: Imp.LM.Static,
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
  Imp.rlm("context, question -> answer",
    lm: controller_lm,
    tools: [lookup],
    max_iterations: 20,
    max_llm_calls: 50,
    max_recursion_depth: 1,
    max_interpreter_value_bytes: 16_000_000,
    max_interpreter_effects: 100,
    max_time_ms: 30_000
  )

Imp.call(rlm, %{context: long_context, question: "What matters?"})
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
  Imp.rlm_serializable(:large_context, fn ->
    File.read!("large-report.txt")
  end,
    metadata: %{source: "large-report.txt"}
  )

Imp.call(rlm, %{large_context: context, question: "What changed?"})
```

The controller initially sees only metadata for the serializable value. The
`load/1` materializes it into the RLM variable space. `llm_query_batched/1`
runs sub-LM calls concurrently through supervised BEAM tasks, preserves result
order, and atomically reserves every item against the shared `max_llm_calls`
ledger. Per-item failures remain ordered string values beginning with `Error:`.
The ledger scope is `subcalls_only`: sub-LM calls made inside recursive children
share it, while root and child controller turns, extraction, and compaction
generations do not consume it. The optional deadline is shared by the complete
recursive call tree; omitting `max_time_ms` configures no RLM deadline. If
controller code submits malformed output, Imp records
the parse feedback as an observation and gives the controller another turn. If
the loop exhausts its iteration budget, Imp runs an extract pass over the
variables, observations, and trace to recover final structured output when
possible. A zero-iteration RLM still fails immediately without spending a
provider call.

## Save And Load

```elixir
program = Imp.predict("question -> answer")

path = Path.join(System.tmp_dir!(), "imp-program.json")
Imp.save!(program, path)
loaded = Imp.load!(path)
File.rm(path)
```

File artifacts use a versioned, checksummed envelope and atomic same-directory
replacement. Callback-bearing programs use trusted names:

```elixir
metric = fn _example, prediction -> Imp.get(prediction, :answer, "") != "" end
registry = Imp.Saving.Registry.new(quality_metric: metric)
program = Imp.Predict.BestOfN.new(program, metric)

Imp.save!(program, path, registry: registry)
loaded = Imp.load!(path, registry: registry)
```

The deploying application must provide every referenced callback with the
expected arity. Unknown names and malformed or tampered artifacts fail before a
program is returned.

DSPy 3.3.0b1 has two persistence modes. `module.save("state.json")` plus
`module.load("state.json")` applies parameter state to an existing Python
program; the Imp-native data boundary is `Imp.dump/1` and `Imp.load/1`, or
their checksummed file equivalents `Imp.save!/2` and `Imp.load!/1`. DSPy's
`module.save(path, save_program: true)` plus `dspy.load(path, allow_pickle:
true)` serializes executable Python with `cloudpickle`. Imp intentionally has
no executable-code artifact mode: its documented artifact boundary is the
allowlisted JSON program representation. Callback closures are stored only as
names from `Imp.Saving.Registry`, and runtime credentials are rebound
explicitly.

Secrets are not persisted. Loaded HTTP LMs do not silently bind ambient
credentials. Rebind a freshly configured LM explicitly before live use:

```elixir
lm =
  Imp.req_llm("openai:" <> System.fetch_env!("OPENAI_MODEL"),
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    temperature: 0
  )

loaded = Imp.with_lm(loaded, lm)
Imp.call(loaded, %{question: "What changed?"})
```

Portable saving supports the program types accepted by `Imp.Saving`, including
compiled few-shot and ensemble graphs, callback wrappers, agents, and RAG
programs backed by `Imp.memory/2`. External service clients remain host-owned.
Functions and tool closures must have stable names in a supplied registry; an
unregistered closure fails during dumping instead of entering the artifact.

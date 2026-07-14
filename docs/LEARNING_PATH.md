# Learning Path

This is the canonical DSEx path. Work through it in order: each local snippet
is deterministic and executed by `test/learning_path_contract_test.exs`. The
only provider-backed snippet is labeled credential-gated.

DSEx follows the DSPy idea that an LM program should be a declarative,
measurable object rather than a prompt string. Its Elixir realization is a
struct with explicit fields, behaviours at runtime boundaries, and values that
fit naturally in ExUnit and OTP applications.

## 1. State The Contract

A signature names the inputs and outputs. `Predict` is the default module: one
validated model call from that contract to a `DSEx.Prediction`. Start here
instead of building an agent or assembling provider messages yourself.

```elixir
# learning-path-contract: predict
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program =
  "question -> answer: short_span"
  |> DSEx.signature("Answer with the shortest correct span.")
  |> DSEx.predict(lm: lm)

{:ok, prediction} = DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})
DSEx.get(prediction, :answer)
```

`DSEx.LM.Static` makes the task contract testable without a provider. In an
application, pass the LM to the program when its dependency should be explicit,
or use `DSEx.context/2` for a request-scoped override.

## 2. Measure Before Changing It

An evaluator applies one metric to labeled examples and returns an aggregate
score plus per-example rows. This is the quality boundary that makes a change
meaningful. Keep a held-out set for release decisions.

```elixir
# learning-path-contract: evaluate
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

program = DSEx.predict("question -> answer", lm: lm)

devset = [
  DSEx.example(question: "Capital of France?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

report = DSEx.evaluate(program, devset, DSEx.exact_match(:answer))
report.score
```

Use `DSEx.exact_match/1` when it represents the product requirement. For a
different requirement, write a two- or three-arity metric that returns a
boolean, number, or structured score with feedback. Inspect `report.rows` when
the aggregate does not explain a failure.

## 3. Improve With Measured Lift

An optimizer compiles a program into a candidate program. `LabeledFewShot`
attaches selected labeled demonstrations; search optimizers such as
`RandomSearch`, `MIPROv2`, and `GEPA` use the same metric to compare candidate
programs. The important result is a score change on data that was not used to
select the candidate.

```elixir
# learning-path-contract: optimize
lm = %{
  module: DSEx.LM.Static,
  opts: [
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "[[ ## answer ## ]]\nParis", do: %{answer: "Paris"}, else: %{answer: "unknown"}
    end
  ]
}

program = DSEx.predict("question -> answer", lm: lm)

trainset = [
  DSEx.example(question: "What is the capital of France?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

devset = [
  DSEx.example(question: "Capital of France?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

metric = DSEx.exact_match(:answer)
baseline = DSEx.evaluate(program, devset, metric).score
compiled = DSEx.optimize(program, DSEx.Optimizer.LabeledFewShot.new(k: 1), trainset)
lifted = DSEx.evaluate(compiled, devset, metric).score
{baseline, lifted}
```

The contract returns `{0.0, 1.0}`. That is a deliberately small proof that the
program changed and the measurement detected a lift. In a real workflow, split
train, development, and held-out release data; do not describe an optimization
as an improvement until the held-out score supports it.

## 4. Give The Program Bounded Actions

ReAct is for tasks that need the model to choose an action, observe its result,
and then submit typed outputs. A `DSEx.Tool` is a named unary Elixir function;
the policy is the capability boundary. The reserved `submit` tool validates the
original signature, so a tool loop cannot bypass the output contract.

```elixir
# learning-path-contract: react
Process.put(:learning_path_react_actions, [
  %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
  %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
])

try do
  lm = %{
    module: DSEx.LM.Static,
    opts: [
      handler: fn _messages, _opts ->
        [action | rest] = Process.get(:learning_path_react_actions)
        Process.put(:learning_path_react_actions, rest)
        action
      end
    ]
  }

  lookup = DSEx.tool(:lookup, "Look up a capital", fn %{query: "capital-france"} -> "Paris" end)
  program = DSEx.react("question -> answer: short_span", [lookup], lm: lm, tool_policy: [:lookup, :submit])

  {:ok, prediction} = DSEx.call(program, %{question: "What is France's capital?"})
  DSEx.get(prediction, :answer)
after
  Process.delete(:learning_path_react_actions)
end
```

Keep tool schemas, authorization, timeouts, idempotency, and audit boundaries
in the host application. Use `ReAct` when the model needs to choose an action;
call a regular Elixir function directly when the application already knows the
action.

## 5. Retrieve Context Deliberately

Retrieval supplies context; it does not replace evaluation. `DSEx.memory/2` is
a deterministic in-memory retriever for tests and local workflows. `DSEx.rag/3`
retrieves, injects a context field, calls the wrapped program, and records the
retrieved documents in prediction metadata.

```elixir
# learning-path-contract: retrieval
lm = %{
  module: DSEx.LM.Static,
  opts: [
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, " ", & &1.content)
      if prompt =~ "France has capital Paris", do: %{answer: "Paris"}, else: %{answer: "unknown"}
    end
  ]
}

retriever = DSEx.memory([%{id: "france", text: "France has capital Paris"}], k: 1)
base = DSEx.predict("question, context -> answer", lm: lm)
program = DSEx.rag(base, retriever, k: 1)

{:ok, prediction} = DSEx.call(program, %{question: "capital France"})
{DSEx.get(prediction, :answer), prediction.metadata.retrieval.count}
```

For an external store, implement the `DSEx.Retrieve` behaviour or pass a
two-argument retriever function that returns `{:ok, docs}`. Evaluate retrieval
and answer quality together, including cases where the relevant document is
missing or misleading.

## 6. Use RLM For Large-Context Control

RLM is a recursive controller, not a synonym for RAG. It gives a controller LM
a constrained persistent Elixir environment and bounded operations such as
safe evaluation, sub-LM calls, recursion, loading serializable inputs, tools,
and `submit/1`. Budgets cover iterations, sub-LM calls, recursion depth, time,
and interpreter work.

```elixir
# learning-path-contract: rlm
controller = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{code: ~S|submit(%{answer: "Paris"})|} end]
}

program = DSEx.rlm("question -> answer", lm: controller, max_iterations: 1)
{:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
{DSEx.get(prediction, :answer), Enum.map(prediction.metadata.rlm_trace, & &1.action)}
```

Use RLM when a controller must explore or compute over context through those
bounded actions. Set budgets before exposing production data, and inspect the
redacted RLM trace before increasing them.

## 7. Persist Programs, Not Secrets

`DSEx.dump/1` and `DSEx.load/1` round-trip a portable program representation.
`DSEx.save!/2` and `DSEx.load!/1` use JSON artifacts. Provider credentials are
not persisted; rebind a loaded program with `DSEx.with_lm/2` or a scoped
`DSEx.context/2`. Functions such as tools and custom metrics require named
entries in `DSEx.Saving.Registry` before they can be saved.

```elixir
# learning-path-contract: persistence
lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

path = Path.join(System.tmp_dir!(), "dsex-learning-path-#{System.unique_integer([:positive])}.json")

try do
  program = DSEx.predict("question -> answer", lm: lm)
  :ok = DSEx.save!(program, path)
  loaded = DSEx.load!(path)

  {:ok, prediction} = DSEx.context([lm: lm], fn -> DSEx.call(loaded, %{question: "Capital of France?"}) end)
  DSEx.get(prediction, :answer)
after
  File.rm(path)
end
```

Treat an artifact as deployable program state. Review and version it alongside
the metric and evaluation data that justified promotion.

## 8. Inspect Runtime Behavior

`DSEx.trace/2` captures selected redacted telemetry while a function runs.
`DSEx.Observability.inspect_artifact/2`, `DSEx.inspect_history/2`, and
`DSEx.Observability.status/1` provide bounded, redacted views of predictions,
tool history, RLM traces, optimizer reports, and provider state. Subscribe with
`DSEx.subscribe_optimizer_progress/1` when an interactive process needs
optimizer progress events.

```elixir
# learning-path-contract: observability
tool = DSEx.tool(:lookup, "Look up a capital", fn %{country: "France"} -> "Paris" end)

trace =
  DSEx.trace(fn ->
    DSEx.Tool.call(tool, %{country: "France"})
  end)

{trace.result, Enum.map(trace.events, &elem(&1, 0))}
```

Telemetry is an observation boundary, not an authorization boundary. Keep
redaction enabled unless debugging a controlled local input, and send the
normalized status data to the application's metrics and alerting system.

## 9. Deploy The Verified Artifact

The supplied `examples/deployment` OTP application
loads a checksummed artifact during supervised startup, binds credentials only
at runtime, and executes requests in bounded `Task.Supervisor` workers. It
returns overloads and timeouts instead of letting one slow provider call block
the program server. Its behavior is exercised by
`test/deployment_reference_test.exs`.

For an application deployment, keep the artifact path, model name, API key,
maximum concurrency, shutdown timeout, retry policy, and retention policy in
runtime configuration. Evaluate the candidate before promotion, load the
artifact through a trusted registry, rebind the live LM, and observe status,
latency, validation errors, and costs after rollout.

## Live Provider Boundary

The local contracts above do not use provider credentials. This snippet is
credential-gated: execute it only when `OPENAI_API_KEY` and `OPENAI_MODEL` are
set, and keep it out of ordinary unit tests. The program and metric APIs do not
change.

```elixir
# learning-path-credential-gated: live_provider
lm =
  DSEx.req_llm("openai:" <> System.fetch_env!("OPENAI_MODEL"),
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    temperature: 0
  )

program = DSEx.predict("question -> answer: short_span", lm: lm)
DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})
```

Run the repository's opt-in provider checks with `LIVE_PROVIDER=1 mix
live.check`. For everyday local validation, run `mix format --check-formatted`
and `mix test test/learning_path_contract_test.exs`. From a source checkout,
run `mix production.check` for the full quality gate.

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
retrievers and functions should be rebound by the caller instead of serialized.

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

Use:

| Optimizer | Use it when |
| --- | --- |
| `LabeledFewShot` | You already have good examples and want demos quickly. |
| `BootstrapFewShot` | A teacher program can generate candidate demos. |
| `RandomSearch` | You want a small deterministic baseline search. |
| `InstructionSearch` / `COPRO` | Instructions are the likely bottleneck. |
| `MIPROv2` / `SIMBA` | You want broader instruction/demo search with stronger evaluation discipline. |
| `GEPA` | You want DSEx-native GEPA-style reflection over program instructions, with comparative claims handled by the parity gates. |
| `BetterTogether` | You want to sequence prompt optimization and provider training. |

Optimizers that use an LM for proposal or reflection, such as COPRO, SIMBA,
and GEPA-style artifact optimization, use the same explicit LM shapes as
programs. `proposer_lm:`, `judge_lm:`, and `reflection_lm:` reject malformed
values when the optimizer is built or run, before a search loop starts.

## Optimize Arbitrary Artifacts

```elixir
artifact = DSEx.Optimize.Anything.new_artifact(:config, "mode=slow")

report =
  DSEx.Optimize.Anything.optimize(
    artifact,
    fn artifact, _examples ->
      if artifact.text =~ "mode=fast", do: 1.0, else: 0.0
    end,
    trials: 1,
    mutation_fn: fn _artifact, _trial, _seed -> "mode=fast" end
  )

report.best.score
```

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
      %{action: "submit", result: %{answer: "Prefer concise answers backed by evidence."}}
    end
  ]
}

long_context = "priority: concise answers backed by evidence"

rlm =
  DSEx.rlm("context, question -> answer",
    lm: controller_lm,
    tools: [lookup],
    max_iterations: 10,
    max_llm_calls: 20,
    max_time_ms: 30_000
  )

DSEx.call(rlm, %{context: long_context, question: "What matters?"})
```

RLM controller actions:

```elixir
%{action: "eval", code: "x + 1"}
%{action: "assign", name: "scratch", value: "note"}
%{action: "load", name: "large_context"}
%{action: "tool", name: "lookup", arguments: %{"key" => "x"}}
%{action: "llm_query", signature: "question -> answer", inputs: %{question: "q"}}
%{action: "llm_query_batched", signature: "question -> answer", inputs: [%{question: "q1"}, %{question: "q2"}]}
%{action: "recurse", signature: "question -> answer", inputs: %{question: "q"}}
%{action: "submit", result: %{answer: "final"}}
```

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
`load` action materializes it once into the RLM variable space. `llm_query_batched`
runs sub-LM calls concurrently, preserves result order, and counts every item
against `max_llm_calls`. If a controller submits malformed output, DSEx records
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

Secrets are not persisted. Loaded HTTP LMs do not silently bind ambient
credentials; reconfigure credentials explicitly before live use. Portable
saving supports `Predict`, `ChainOfThought`, and RAG programs backed by
`DSEx.memory/2`. Programs that hold functions, external service clients,
or live tool closures should be rebuilt by application code.

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

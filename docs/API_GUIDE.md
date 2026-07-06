# API Guide

This guide is organized around the things you build.

## Configure An LM

Use the `DSEx` facade for application code. Reach for deeper
`DSEx.*` modules when you need direct control over adapters, optimizers,
tools, agents, or persistence.

For deterministic examples:

```elixir
lm = %{
  module: DSEx.LM.Fake,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)
```

For a live OpenAI-compatible provider:

```elixir
lm = DSEx.openai("gpt-4o-mini", opts: [temperature: 0])
DSEx.configure(lm: lm)
```

The provider client reads `OPENAI_API_KEY` unless `api_key:` is supplied.

## Basic Predict

```elixir
program = DSEx.predict("question -> answer")
{:ok, pred} = DSEx.call(program, %{question: "Capital of France?"})
DSEx.get(pred, :answer)
```

## Chain Of Thought

```elixir
program = DSEx.chain_of_thought("question -> answer")
{:ok, pred} = DSEx.call(program, %{question: "2+2?"})

DSEx.get(pred, :reasoning)
DSEx.get(pred, :answer)
```

## Schema-Constrained JSON

```elixir
signature =
  DSEx.Signature.new(%{
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

## Examples And Demos

```elixir
demo =
  DSEx.example(question: "2+2?", answer: "4")
  |> DSEx.Example.with_inputs(:question)

program =
  "question -> answer"
  |> DSEx.predict()
  |> DSEx.Predict.Predict.with_demos([demo])
```

## Evaluate A Program

```elixir
devset = [
  DSEx.example(question: "Capital of France?", answer: "Paris") |> DSEx.Example.with_inputs(:question)
]

metric = DSEx.Metrics.exact_match(:answer)
evaluator = DSEx.Evaluate.new(devset, metric)
report = DSEx.Evaluate.run(evaluator, program)
report.score
```

## Optimize A Program

```elixir
optimizer = DSEx.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
compiled = DSEx.Optimizer.RandomSearch.compile(optimizer, program, trainset, devset)

DSEx.Optimizer.Report.fetch(compiled)
```

Use:

- `LabeledFewShot` for quick demos.
- `BootstrapFewShot` when a teacher can generate examples.
- `RandomSearch` for small deterministic searches.
- `InstructionSearch`, `COPRO`, `MIPROv2`, `SIMBA` for instruction/demo search.
- `BetterTogether` to sequence prompt and weight optimizers.

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

## Tools And ReActV2

```elixir
lookup =
  DSEx.Tool.new(:lookup, "lookup facts", fn
    %{query: "capital-france"} -> "Paris"
  end)

agent = DSEx.react_v2("question -> answer", [lookup], tool_policy: [:lookup])
```

`ReActV2` expects the LM to produce provider-style tool calls. A reserved
`submit` tool validates final outputs against the original signature.

## Agents

```elixir
tool = DSEx.Tool.new(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

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

For HTTP-backed discovery:

```elixir
client = DSEx.MCP.HTTPClient.new("https://mcp.example/tools")
tools = DSEx.MCP.import_tools(client)
```

## RLM

```elixir
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
%{action: "tool", name: "lookup", arguments: %{"key" => "x"}}
%{action: "llm_query", signature: "question -> answer", inputs: %{question: "q"}}
%{action: "submit", result: %{answer: "final"}}
```

## Save And Load

```elixir
DSEx.Saving.save!(program, "tmp/program.json")
loaded = DSEx.Saving.load!("tmp/program.json")
```

Secrets are not persisted. Loaded HTTP LMs do not silently bind ambient
credentials; reconfigure credentials explicitly before live use.

## Streaming

```elixir
DSEx.Streaming.stream(program, %{question: "q"}) |> Enum.to_list()
```

Provider SSE streaming is covered through injectable transports.

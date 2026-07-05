# API Guide

This guide is organized around the things you build.

## Configure An LM

For deterministic examples:

```elixir
lm = %{
  module: DSPy.LM.Fake,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

DSPy.configure(lm: lm, adapter: DSPy.Adapter.Chat)
```

For a live OpenAI-compatible provider:

```elixir
lm = DSPy.openai("gpt-4o-mini", opts: [temperature: 0])
DSPy.configure(lm: lm)
```

The provider client reads `OPENAI_API_KEY` unless `api_key:` is supplied.

## Basic Predict

```elixir
program = DSPy.predict("question -> answer")
{:ok, pred} = DSPy.Predict.Predict.call(program, %{question: "Capital of France?"})
DSPy.Prediction.get(pred, :answer)
```

## Chain Of Thought

```elixir
program = DSPy.chain_of_thought("question -> answer")
{:ok, pred} = DSPy.Predict.ChainOfThought.call(program, %{question: "2+2?"})

DSPy.Prediction.get(pred, :reasoning)
DSPy.Prediction.get(pred, :answer)
```

## Schema-Constrained JSON

```elixir
signature =
  DSPy.Signature.new(%{
    inputs: [:text],
    outputs: [
      %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })

program = DSPy.predict(signature, adapter: DSPy.Adapter.JSON)
```

The JSON adapter validates output fields and returns retry feedback for schema
violations.

## Examples And Demos

```elixir
demo =
  DSPy.example(question: "2+2?", answer: "4")
  |> DSPy.Example.with_inputs(:question)

program =
  "question -> answer"
  |> DSPy.predict()
  |> DSPy.Predict.Predict.with_demos([demo])
```

## Evaluate A Program

```elixir
devset = [
  DSPy.example(question: "Capital of France?", answer: "Paris") |> DSPy.Example.with_inputs(:question)
]

metric = DSPy.Metrics.exact_match(:answer)
evaluator = DSPy.Evaluate.new(devset, metric)
report = DSPy.Evaluate.run(evaluator, program)
report.score
```

## Optimize A Program

```elixir
optimizer = DSPy.Teleprompt.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
compiled = DSPy.Teleprompt.RandomSearch.compile(optimizer, program, trainset, devset)

DSPy.Teleprompt.Report.fetch(compiled)
```

Use:

- `LabeledFewShot` for quick demos.
- `BootstrapFewShot` when a teacher can generate examples.
- `RandomSearch` for small deterministic searches.
- `InstructionSearch`, `COPRO`, `MIPROv2`, `SIMBA` for instruction/demo search.
- `BetterTogether` to sequence prompt and weight optimizers.

## Optimize Arbitrary Artifacts

```elixir
artifact = DSPy.Optimize.Anything.new_artifact(:config, "mode=slow")

report =
  DSPy.Optimize.Anything.optimize(
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
artifact = DSPy.Optimize.Anything.new_artifact(:prompt, "Base")

report =
  DSPy.Optimize.GEPA.optimize(
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
  DSPy.Tool.new(:lookup, "lookup facts", fn
    %{query: "capital-france"} -> "Paris"
  end)

agent = DSPy.react_v2("question -> answer", [lookup], tool_policy: [:lookup])
```

`ReActV2` expects the LM to produce provider-style tool calls. A reserved
`submit` tool validates final outputs against the original signature.

## Agents

```elixir
tool = DSPy.Tool.new(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

agent =
  DSPy.Agent.new(:doubler, fn agent, %{x: x}, runtime ->
    DSPy.Agent.call_tool(agent, :double, %{x: x}, runtime)
  end, tools: [tool], tool_policy: [:double])

{:ok, output, runtime} = DSPy.Agent.run(agent, %{x: 4})
```

For incremental traces:

```elixir
DSPy.Agent.stream_events(agent, %{x: 4}) |> Enum.to_list()
```

## MCP Import

```elixir
catalog =
  DSPy.MCP.Catalog.new([
    %{name: :lookup, description: "lookup", input_schema: %{required: [:key]}, run: & &1}
  ])

[tool] = DSPy.MCP.import_tools(catalog)
```

For HTTP-backed discovery:

```elixir
client = DSPy.MCP.HTTPClient.new("https://mcp.example/tools")
tools = DSPy.MCP.import_tools(client)
```

## RLM

```elixir
rlm =
  DSPy.rlm("context, question -> answer",
    lm: controller_lm,
    tools: [lookup],
    max_iterations: 10,
    max_llm_calls: 20,
    max_time_ms: 30_000
  )

DSPy.Predict.RLM.call(rlm, %{context: long_context, question: "What matters?"})
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
DSPy.Saving.save!(program, "tmp/program.json")
loaded = DSPy.Saving.load!("tmp/program.json")
```

Secrets are not persisted. Loaded HTTP LMs do not silently bind ambient
credentials; reconfigure credentials explicitly before live use.

## Streaming

```elixir
DSPy.Streaming.stream(program, %{question: "q"}) |> Enum.to_list()
```

Provider SSE streaming is covered through injectable transports.

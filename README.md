# DSEx

Declarative, testable language-model programs for Elixir.

DSEx lets you describe an LM task as a small typed signature, run it through
ordinary Elixir data structures, evaluate it on examples, and improve it with
optimizers. It is inspired by the DSPy family of ideas, but designed as an
Elixir library: explicit structs, behaviours, OTP-friendly clients, supervised
runtime boundaries, process-local configuration, and local quality gates you can
run in CI.

Use DSEx when prompts have grown into application logic and you want them to
become code: named inputs and outputs, schema validation, traces, metrics,
examples, retrieval, tools, agents, and repeatable evaluation.

## A Tiny Program

```elixir
Mix.install([
  {:dsex, "~> 0.1.0"}
])
```

When running this snippet from a source checkout before DSEx is published, use
the local path dependency instead:

```elixir
Mix.install([
  {:dsex, path: "."}
])
```

Then declare and call the program:

```elixir

lm =
  %{
    module: DSEx.LM.Static,
    opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
  }

DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)

program =
  "question -> answer: short_span"
  |> DSEx.signature(
    "Answer with the shortest correct span. Do not explain."
  )
  |> DSEx.predict()

{:ok, prediction} =
  DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})

DSEx.get(prediction, :answer)
#=> "Paris"
```

Swap in a real provider by changing only the LM client:

```elixir
lm =
  DSEx.req_llm("openai:#{System.fetch_env!("OPENAI_MODEL")}",
    temperature: 0,
    api_key: System.fetch_env!("OPENAI_API_KEY")
  )

DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)
```

The program stays the same. That is the point: your task contract, adapters,
metrics, and optimizers are ordinary Elixir values, while the LM is just a
runtime dependency.

You can also build the same program without the pipe:

```elixir
signature =
  DSEx.signature(
    "question -> answer: short_span",
    "Answer with the shortest correct span. Do not explain."
  )

program = DSEx.predict(signature)
```

## What You Get

| Area | What to use first | What it gives you |
| --- | --- | --- |
| Task contracts | `DSEx.signature/2` | Named inputs/outputs, types, instructions, constraints |
| Calling models | `DSEx.predict/2` | One LM call with validated structured output |
| Testing | `DSEx.LM.Static` | Deterministic examples without provider credentials |
| Providers | `DSEx.req_llm/2` | ReqLLM-backed access to production model APIs |
| Evaluation | `DSEx.evaluate/4`, `DSEx.Metrics` | Scores, feedback, traces, metric metadata |
| Optimization | `DSEx.optimize/4`, `DSEx.Optimizer.*` | Better demos, instructions, and program variants |
| Retrieval | `DSEx.memory/2`, `DSEx.retrieve/3`, `DSEx.rag/3` | Local retrieval and retrieval-augmented programs |
| Tools | `DSEx.react/3`, `DSEx.tool/4` | Tool-calling programs with validated final submission |
| Agents | `DSEx.Agent` | Explicit Elixir runtimes with tools and event streams |
| Advanced loops | CodeAct, program-of-thought, recursive control | Sandboxed code/tool/recurse workflows for harder tasks |
| Maintainer source-checkout gates | `mix production.check` | Repository release checks for formatting, compile, tests, package shape, Livebook validation, and docs |

## Installation

For local development:

```sh
git clone https://github.com/deepfates/dsex.git
cd dsex
mix deps.get
mix test
```

In another project, use the Hex package once published, or a Git dependency
while working directly from this repository:

```elixir
def deps do
  [
    {:dsex, github: "deepfates/dsex"}
  ]
end
```

## Your First DSEx App

In a new Elixir app, keep the first DSEx program deterministic and testable:

```sh
mix new qa_bot --sup
cd qa_bot
```

Add DSEx to `mix.exs`, then write a normal ExUnit test:

```elixir
defmodule QaBotTest do
  use ExUnit.Case

  test "answers through a declared DSEx program" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program =
      "question -> answer: short_span"
      |> DSEx.signature("Answer with the shortest correct span.")
      |> DSEx.predict(lm: lm)

    assert {:ok, prediction} =
             DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})

    assert DSEx.get(prediction, :answer) == "Paris"
  end
end
```

When the test is useful, move the LM dependency to runtime configuration or a
request-scoped `DSEx.context/2` call:

```elixir
lm =
  DSEx.req_llm("openai:#{System.fetch_env!("OPENAI_MODEL")}",
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    temperature: 0
  )

DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
  DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})
end)
```

## Common Workflows

### Typed Outputs

```elixir
signature =
  DSEx.signature(
    "text -> sentiment: enum[positive,negative], confidence: number",
    "Classify the sentiment of the text."
  )

program = DSEx.predict(signature, adapter: DSEx.Adapter.JSON)
```

The JSON adapter validates the model output and returns retry feedback when a
field is missing or violates the schema.

### Evaluation

```elixir
qa_lm = %{
  module: DSEx.LM.Static,
  opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
}

qa_program = DSEx.predict("question -> answer", lm: qa_lm)

devset = [
  DSEx.example(question: "Capital of France?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

metric = DSEx.exact_match(:answer)

report = DSEx.evaluate(qa_program, devset, metric)

report.score
```

Metrics can return booleans, numeric scores, or structured maps with feedback
and metadata. Extractive QA tasks can use `DSEx.extractive_qa/3` to
record exact match, F1, answer type, and span relation.

### Optimization

```elixir
trainset = [
  DSEx.example(question: "Eiffel Tower city?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

optimizer =
  DSEx.Optimizer.RandomSearch.new(metric,
    candidates: 8,
    demos_per_candidate: 2
  )

compiled =
  DSEx.optimize(
    qa_program,
    optimizer,
    trainset,
    devset
  )
```

DSEx optimizers compile programs into better programs. Reports are persisted as
data, so you can inspect what changed and why.

### Tools And ReAct

```elixir
tool_lm = %{
  module: DSEx.LM.Static,
  opts: [
    handler: fn _messages, _opts ->
      %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
    end
  ]
}

lookup =
  DSEx.tool(:lookup, "lookup facts", fn %{query: "capital-france"} ->
    "Paris"
  end)

react =
  DSEx.react("question -> answer: short_span", [lookup],
    lm: tool_lm,
    tool_policy: [:lookup, :submit]
  )
```

Tool policies make side effects explicit. ReAct uses provider tool calls when
the configured LM supports them and validates final submissions against the
original signature. For long-running agent runtimes with event streams, see
the Agents section in `docs/API_GUIDE.md` or Livebook 03.

## Documentation

Start here:

- [Documentation Guide](docs/README.md)
- [Learning Path](docs/LEARNING_PATH.md)
- [API Guide](docs/API_GUIDE.md)
- [Glossary](docs/GLOSSARY.md)
- [Philosophy](docs/DSEX_PHILOSOPHY.md)
- [Production Operations](docs/PRODUCTION_OPERATIONS.md)

The `livebooks/` directory contains runnable tutorials:

- `01_programming_not_prompting.livemd`
- `02_evaluate_and_optimize.livemd`
- `03_agents_tools_mcp_rlm.livemd`
- `04_local_gates_and_live_provider_smoke.livemd`

## Validation

From the source checkout, the everyday local quality gate checks the package
without spending provider tokens or depending on external datasets:

```sh
mix production.check
```

It runs formatting, compilation with warnings as errors, deterministic tests,
package-boundary checks, Livebook validation, and ExDoc generation.

When you change public examples or teaching material in the source checkout,
also execute the shipped notebooks end to end:

```sh
mix livebook.execute.check
```

Provider-backed source-checkout checks are opt-in because they use live
credentials:

```sh
LIVE_PROVIDER=1 mix live.check
```

Maintainer release-evidence commands live outside the normal product workflow.
They are documented for reviewers who need to audit DSEx-vs-DSPy parity and
performance claims.

## Why Elixir?

LM programs need the same things other production systems need: boundaries,
observability, concurrency, supervised work, deterministic tests, and clear
data contracts. Elixir is good at those things. DSEx tries to make language
model behavior feel less like a pile of prompts and more like a system you can
inspect, test, optimize, and operate.

## Prior Art

DSEx owes a clear conceptual debt to DSPy, Ax, GEPA, and optimize-anything
style systems. It is not a Python compatibility layer. The goal is the same
philosophy in an Elixir shape: declarative task contracts, measurable behavior,
and self-improvement loops built from ordinary language and data.

See [Prior Art](docs/PRIOR_ART.md) for the longer lineage.

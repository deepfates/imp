# DSEx

Declarative, testable language-model programs for Elixir.

DSEx lets you describe an LM task as a small typed signature, run it through
ordinary Elixir data structures, evaluate it on examples, and improve it with
optimizers. It is inspired by the DSPy family of ideas, but designed as an
Elixir library: explicit structs, behaviours, OTP-friendly clients, supervised
runtime boundaries, process-local configuration, and production gates you can
run in CI.

Use DSEx when prompts have grown into application logic and you want them to
become code: named inputs and outputs, schema validation, traces, metrics,
examples, retrieval, tools, agents, and repeatable evaluation.

## A Tiny Program

```elixir
Mix.install([
  {:dsex, path: "."}
])

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
| Evaluation | `DSEx.Evaluate`, `DSEx.Metrics` | Scores, feedback, traces, metric metadata |
| Optimization | `DSEx.Optimizer.*` | Better demos, instructions, and program variants |
| Tools | `DSEx.react/3`, `DSEx.tool/4` | Tool-calling programs with validated final submission |
| Agents | `DSEx.Agent` | Explicit Elixir runtimes with tools and event streams |
| Advanced loops | CodeAct, program-of-thought, recursive control | Sandboxed code/tool/recurse workflows for harder tasks |
| Operations | `mix production.check` | Local gates for formatting, compile, tests, package shape, and docs |

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
devset = [
  DSEx.example(question: "Capital of France?", answer: "Paris")
  |> DSEx.with_inputs(:question)
]

metric = DSEx.Metrics.exact_match(:answer)

report =
  devset
  |> DSEx.Evaluate.new(metric)
  |> DSEx.Evaluate.run(program)

report.score
```

Metrics can return booleans, numeric scores, or structured maps with feedback
and metadata. Extractive QA tasks can use `DSEx.Metrics.extractive_qa/3` to
record exact match, F1, answer type, and span relation.

### Optimization

```elixir
optimizer =
  DSEx.Optimizer.RandomSearch.new(metric,
    candidates: 8,
    demos_per_candidate: 2
  )

compiled =
  DSEx.Optimizer.RandomSearch.compile(
    optimizer,
    program,
    trainset,
    devset
  )
```

DSEx optimizers compile programs into better programs. Reports are persisted as
data, so you can inspect what changed and why.

### Tools And Agents

```elixir
lookup =
  DSEx.tool(:lookup, "lookup facts", fn %{query: "capital-france"} ->
    "Paris"
  end)

agent =
  DSEx.react("question -> answer: short_span", [lookup],
    tool_policy: [:lookup, :submit]
  )
```

Tool policies make side effects explicit. ReAct uses provider tool calls when
the configured LM supports them and validates final submissions against the
original signature.

## Documentation

Start here:

- [Documentation Guide](docs/README.md)
- [API Guide](docs/API_GUIDE.md)
- [Philosophy](docs/DSEX_PHILOSOPHY.md)
- [Production Operations](docs/PRODUCTION_OPERATIONS.md)

The `livebooks/` directory contains runnable tutorials:

- `01_programming_not_prompting.livemd`
- `02_evaluate_and_optimize.livemd`
- `03_agents_tools_mcp_rlm.livemd`
- `04_production_and_live_provider.livemd`

## Validation

The everyday local gate proves the package is shippable without spending
provider tokens or depending on external datasets:

```sh
mix production.check
```

It runs formatting, compilation with warnings as errors, deterministic tests,
package-boundary checks, and ExDoc generation.

Provider-backed checks are opt-in because they use live credentials:

```sh
LIVE_PROVIDER=1 mix live.check
```

Maintainer evidence commands for benchmark truth, golden traces, optimizer
lift, and parity research live behind `mix evidence.check` and the benchmark
Mix tasks. They are release evidence, not the normal product workflow.

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

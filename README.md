# Imp

Declarative, self-improving language-model programs for Elixir.

<!-- "Imp with cards", Le Grand Etteilla (public domain, via Wikimedia Commons) -->
<p align="center">
  <img src="assets/imp-with-cards.jpg" width="300"
       alt="An imp studies a hand of cards through a lens while a smaller imp springs from its tail.">
</p>

Imp is a full port of [DSPy](https://dspy.ai) to the BEAM. You describe what
each language-model step takes and returns, choose how it thinks, and let an
optimizer improve it against examples of what good looks like. You get
signatures, modules, optimizers, agent loops and retrieval, running with the
reliability and concurrency of OTP.

That pairing is the point. DSPy makes each call to a model a declared,
typed, improvable function. The BEAM makes each agent what it already is: a
process with its own state, a mailbox, and a supervisor. Put together, you
can build anything from one typed call to a crowd of long-running agents,
and make every part of it better by measuring it.

## Declare a task

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

triage =
  "issue -> kind: enum[bug,feature,question], summary"
  |> Imp.signature("Triage a GitHub issue.")
  |> Imp.predict(lm: lm)

{:ok, prediction} =
  Imp.call(triage, %{issue: "App crashes on startup since 0.4 with ** (KeyError) key :lm not found"})

{Imp.get(prediction, :kind), Imp.get(prediction, :summary)}
#=> {"bug", "App crashes on startup since version 0.4 with a KeyError for `:lm` not found."}
```

You never write a prompt or a parser. Imp builds the prompt from the
signature, checks the reply against it, and gives you typed fields: `kind` is
always one of the three values, or the call returns an error. To make the
same task reason first, use `Imp.chain_of_thought/2`; to give it tools, use
`Imp.react/3`. The signature stays the same.

## Measure it and improve it

Give Imp labeled examples and a metric, and it scores the program and
optimizes it. Here `trainset` and `devset` are lists of issues you have
already labeled (`Imp.example/1`, then `Imp.with_inputs/2` to mark the
`issue` as the input), and `strong_lm` is a more
capable model that GEPA uses to reflect on failures:

```elixir
metric = Imp.exact_match(:kind)

Imp.evaluate(triage, devset, metric).score

optimizer = Imp.Optimizer.GEPA.new(metric, reflection_lm: strong_lm, max_metric_calls: 300)
improved = Imp.optimize!(triage, optimizer, trainset, devset)

Imp.evaluate(improved, devset, metric).score
```

GEPA runs the program, reads where it failed, and rewrites its instructions.
Other optimizers choose worked examples (LabeledFewShot, BootstrapFewShot),
search combinations of both (MIPROv2, SIMBA), or train the model's weights
(fine-tuning, GRPO). The result is a new program whose instructions and
examples you can read, save as JSON, and commit like code.

## Build agents

A tool is an Elixir function. `Imp.react/3` builds an agent that calls tools
until it can answer. This one can read web pages, using Req, which comes with
Imp:

```elixir
fetch =
  Imp.tool(:fetch, "Read a web page as text.", fn %{"url" => url} -> Req.get!(url).body end,
    schema: %{"type" => "object", "properties" => %{"url" => %{"type" => "string"}}, "required" => ["url"]}
  )

researcher = Imp.react("question -> answer", [fetch], lm: lm)

question =
  "What version does https://raw.githubusercontent.com/elixir-lang/elixir/main/VERSION say? " <>
    "Reply with just the version."

{:ok, prediction} = Imp.call(researcher, %{question: question})
Imp.get(prediction, :answer)
#=> "1.21.0-dev"
```

## Run agents as processes

`Imp.call/2` runs a program in your process. `Imp.start_run/3` runs it as its
own supervised process instead, so you can watch it, stop it, and decide
which tool calls it may make:

~~~elixir
{:ok, run} =
  Imp.start_run(researcher, %{question: question},
    authorize: fn call ->
      url = call.arguments["url"] || ""

      if String.starts_with?(url, "https://raw.githubusercontent.com/"),
        do: :allow,
        else: {:deny, :untrusted_host}
    end
  )

{:ok, prediction} = Task.await(run.task)

for event <- Imp.Run.events(run), do: event.kind
#=> [:run_started, :tools_sent, :model_request, :model_response, :tool_call,
#    :tool_result, :model_request, :model_response, :run_finished]
~~~

Around that, Imp gives agents what they need to run for a long time:

- **MCP:** import the tools of any MCP server you approve, and they work like
  your own.
- **ACP:** serve any Imp program as an agent to Zed, JetBrains and other ACP
  clients.
- **OTP:** every call is supervised and bounded, and a run ends when the
  process that started it does. A tool call that may already have taken
  effect is reported as unknown, never silently retried.
- **More shapes:** RLM for inputs far larger than a context window, CodeAct
  and program of thought for tasks that need code, and your own modules
  composed from these.

The optimizers work on agents too. GEPA and Optimize Anything read whole
runs and rewrite what steers an agent: its instructions, its tool
descriptions, or any text or JSON it depends on.

## Install

```elixir
{:imp, "~> 0.5"}
```

Imp needs Elixir 1.19 and a C++ compiler for one dependency (erlexec). It
reaches models through [ReqLLM](https://hex.pm/packages/req_llm), so any
provider ReqLLM supports works.

Imp is young. 0.5 is its first Hex release, and its optimizers still need
large-scale benchmarking; the core API is stable, and the parts marked
experimental may change before 1.0. Bug reports and pull requests are very
welcome.

## Learn

- [Getting started](docs/getting-started/index.md) builds one program step by
  step, from the first call to a supervised server, with real scores.
- [Coming from DSPy](docs/coming-from-dspy.md) maps DSPy's names to Imp's.
- [Tutorials](livebooks/01_real_lm_front_door.livemd) are Livebook notebooks
  you can run offline or with a key.
- The [cheatsheet](docs/cheatsheet.cheatmd) has the common calls on one page.

Imp is MIT licensed.

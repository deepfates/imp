# Imp

Imp is [DSPy](https://dspy.ai) for the BEAM: declare a language-model task
as a typed Elixir program, then test, measure, improve, and operate it like
any other code. There are two kinds of intelligence in a modern program,
the fluid kind that can read a situation and the solid kind that does
exactly what it says. Imp is for building programs out of both.

<!-- "Imp with cards", Le Grand Etteilla (public domain, via Wikimedia Commons) -->
<p align="center">
  <img src="assets/imp-with-cards.jpg" width="380"
       alt="An imp studies a hand of cards through a lens while a smaller imp springs from its tail.">
</p>

You declare the task the way you would declare a type, with named inputs,
named outputs, and constraints. Imp turns the declaration into a program.
The program is a value, not a prompt.

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

route =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to the team that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

{:ok, prediction} =
  Imp.call(route, %{ticket: "Customers are seeing other users' invoices in the billing portal."})

Imp.get(prediction, :team)
#=> "security"
```

The model read the situation: an invoice complaint that is really a
security incident. The types held the contract: the answer is always one of
your four teams, and a generation that breaks the declaration is rejected
and retried with the validation error. You never wrote a prompt.

## Install

```elixir
{:imp, github: "deepfates/imp", tag: "v0.1.0"}
```

Imp is not on Hex yet; a Hex release is planned. You will need an API key
for a model provider (any [ReqLLM](https://hex.pm/packages/req_llm)
provider works; the docs use OpenAI).

## Because the program is a value, the rest is ordinary engineering

Each stage below is one stop on the [Learning Path](docs/LEARNING_PATH.md),
which grows this same router end to end.

- **Declare** the task as a typed signature. The prompt is rendered from
  the declaration at call time; you never maintain it.
- **Test** without a provider. A scripted model plays the LM's part while
  the real signature validation, adapters, and metrics run in your suite.
- **Measure** on labeled data. Evaluation returns a score and every row,
  a number instead of an impression.
- **Improve** with an optimizer that compiles a better program. In the
  [tutorial](docs/TUTORIAL_TICKET_ROUTING.md)'s committed runs, the router
  goes from 30% to 85% on tickets it has never seen, for about a cent,
  and you can read exactly what changed, because the optimizer's work is
  data attached to the program.
- **Extend** with typed tools under explicit policies, agent loops from
  ReAct through a sandboxed recursive controller, retrieval, and token
  streaming straight into your LiveView.
- **Operate** it where it belongs. On the BEAM a model call is one more
  slow, fallible, concurrent effect: bounded supervised workers, compiled
  programs persisted as checksummed artifacts with no secrets inside,
  credentials bound at runtime, redacted telemetry on every call, retry,
  and tool step. The [deployment example](examples/deployment) is a
  complete OTP application.

You will use one or two capabilities at first; the rest are there when a
task earns them. The full menu, twenty program shapes and about as many
optimizers, from `ChainOfThought` and the ReAct family through `GEPA`,
`MIPROv2`, weight-level training with local MLX fine-tuning, and
Optimize-Anything for arbitrary text artifacts, lives in the
[API Guide](docs/API_GUIDE.md).

## The port is verified, and you can run the receipts

Imp is a native BEAM realization of DSPy's research program of programming
language models instead of prompting them. It tracks DSPy 3.2.1, and
executable differential tests verify behavior against that pinned upstream
source, so "faithful port" is a claim you can check yourself: the
[conformance report](docs/CONFORMANCE.md) enumerates every surface and its
evidence. Where the BEAM offers more, such as supervision and cheap
concurrency, Imp uses it. [Imp for DSPy users](docs/IMP_FOR_DSPY_USERS.md)
maps every name you already know and states exactly what differs.

## Learn

- [Learning Path](docs/LEARNING_PATH.md): the router above, grown step by
  step from first live call to deployment.
- [Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md): the full
  experiment behind the numbers, artifact included.
- [Livebooks](livebooks/): the same path as runnable notebooks.
- Reference: [API Guide](docs/API_GUIDE.md), [Glossary](docs/GLOSSARY.md),
  [Architecture](docs/ARCHITECTURE.md),
  [Production Operations](docs/PRODUCTION_OPERATIONS.md).

## Where this is going

First, a Hex release. Second, an interactive-fiction environment package,
where an optimizer teaches an agent to survive a classic dungeon and every
episode is a replayable, branchable log. Third, the bet that belongs to
this runtime: optimization as a resident process, programs improving from
their own recorded history, under supervision, while they run.

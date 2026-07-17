# Imp

There are two kinds of intelligence in a modern program. One is fluid: a
language model can read a support ticket and *understand* that customers
seeing each other's invoices is a security incident, not a billing question.
The other is solid: types, functions, supervision trees — structure that does
exactly what it says, every time. Most tools make you pick one and fake the
other. Imp is for building programs out of both.

Here is what that means in practice. You declare a task the way you would
declare a type — named inputs, named outputs, constraints — and Imp turns it
into a program. Not a prompt: a value.

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

route =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to the team that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} =
  Imp.call(route, %{ticket: "Customers are seeing other users' invoices in the billing portal."})

Imp.get(prediction, :team)
#=> "security"
```

Notice what the model did: the ticket talks about invoices, but it read the
situation and routed to security at high urgency. And notice what the *types*
did: the answer is always one of your four teams, because when the model
drifts, Imp rejects the output against the declared enum and retries with the
validation error. You never wrote a prompt, and you never parse free text.

Because the program is a value, everything programs already enjoy now works
on language-model behavior. You can test it against a scripted model without
spending a cent. You can score it on labeled data and get a number instead of
a vibe. And — this is where it gets fun — you can hand it to an optimizer
that rewrites the program until held-out data says it actually got better.
The [tutorial](docs/TUTORIAL_TICKET_ROUTING.md) does exactly that: a router
goes from 35% to 90% on tickets it has never seen, in about twenty seconds,
for about a cent, and you can read precisely what changed — the optimizer's
work is data attached to the program, not magic soaked into a string.

That loop — declare, measure, improve, prove — scales the whole way up:

- **Programs**: `Predict`, `ChainOfThought`, `ReAct` agents with typed tools
  and policies, `CodeAct`, `ProgramOfThought`, refinement, best-of-N,
  parallel fan-out, retrieval-augmented wrappers, and RLM — recursive
  control for inputs too large for any prompt, running in a budgeted,
  supervised Elixir sandbox.
- **Optimizers**: the full modern bench. Few-shot selection
  (`LabeledFewShot`, `BootstrapFewShot`, random search), instruction
  evolution (`COPRO`, `SIMBA`, `MIPROv2`, `GEPA` with reflective text
  feedback), ensembles and `BetterTogether`, and weight-level training —
  `BootstrapFinetune`, `GRPO`, and local MLX fine-tuning — all behind one
  `Imp.optimize` shape, all gated by your metric on held-out data.
- **Beyond prompts**: the Optimize-Anything lane points the same machinery
  at arbitrary text artifacts — code, configs, heuristics — anywhere you can
  score a candidate.

Then you run it where a program like this belongs. On the BEAM, a model call
is just another slow, fallible, concurrent effect — the kind of thing OTP
has supervised for forty years. Compiled programs persist as checksummed
artifacts with no secrets inside; credentials bind at runtime; execution
runs in bounded, supervised workers that return overloads instead of
hanging; telemetry is a built-in sense, not an integration. The
[deployment example](examples/deployment) is a complete OTP application.

Imp is a native BEAM realization of [DSPy](https://dspy.ai)'s research
program — programming, not prompting — and it takes the lineage seriously:
Imp tracks DSPy 3.2.1 and verifies its optimizers against the pinned
upstream source with executable differential tests, so "faithful port" is a
claim you can run, not a vibe. Where the runtimes differ, Imp is honest
about it; where the BEAM offers more — supervision, cheap concurrency,
hot upgrades — Imp uses it.

## Install

Add the release to your `mix.exs` deps:

```elixir
{:imp, github: "deepfates/imp", tag: "v0.1.0"}
```

Imp is not on Hex yet; a Hex release is planned. You will need an API key
for a model provider (any [ReqLLM](https://hex.pm/packages/req_llm)
provider works; the docs use OpenAI).

## Learn

- **[Learning Path](docs/LEARNING_PATH.md)** — one router grown step by step:
  first live call, testing without a provider, metrics, optimization, tools,
  retrieval, persistence, deployment.
- **[Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md)** — the full
  measure-improve-prove experiment with real numbers and costs.
- **[Livebooks](livebooks/)** — the same path as runnable notebooks.
- **[API Guide](docs/API_GUIDE.md)** · **[Glossary](docs/GLOSSARY.md)** ·
  **[Architecture](docs/ARCHITECTURE.md)** ·
  **[Production Operations](docs/PRODUCTION_OPERATIONS.md)**

## Where this is going

The near roadmap, honestly marked as intent rather than achievement: a Hex
release; an interactive-fiction environment package where an optimizer
visibly teaches an agent to survive a classic dungeon, with every episode
recorded as a replayable, branchable log; and — the longer bet native to
this runtime — optimization as a resident process: programs that improve
from their own recorded history, under supervision, while they run.

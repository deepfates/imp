# Imp

There are two kinds of intelligence in a modern program. One is fluid. A
language model can read a support ticket and understand that customers
seeing each other's invoices is a security incident, not a billing question.
The other is solid. Types, functions, and supervision trees do exactly what
they say, every time. Most tools make you pick one and fake the other. Imp
is for building programs out of both.

Here is what that means in practice. You declare a task the way you would
declare a type, with named inputs, named outputs, and constraints, and Imp
turns the declaration into a program. The program is a value, not a prompt.

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

Notice what the model did. The ticket is about invoices, but the model read
the situation and routed it to security at high urgency. Notice what the
types did too. The answer is always one of your four teams, because when the
model returns anything else, Imp rejects the output against the declared
enum and retries with the validation error. You never wrote a prompt.

Because the program is a value, the things you already do to programs now
work on language-model behavior. You can test the router against a scripted
model without spending a cent. You can score it on labeled data and get a
number instead of an impression. You can hand it to an optimizer that
rewrites the program until held-out data shows it got better. In the
[tutorial](docs/TUTORIAL_TICKET_ROUTING.md), a router goes from 35% to 90%
on tickets it has never seen, in about twenty seconds, for about a cent.
You can also read exactly what the optimizer changed, because its work is
data attached to the program.

The loop of declaring, measuring, improving, and proving scales the whole
way up:

- **Programs**: `Predict`, `ChainOfThought`, `ReAct` agents with typed tools
  and policies, `CodeAct`, `ProgramOfThought`, refinement, best-of-N,
  parallel fan-out, retrieval wrappers, and RLM, which gives a model
  recursive control for inputs too large for one prompt, inside a budgeted
  and supervised Elixir sandbox.
- **Optimizers**: few-shot selection (`LabeledFewShot`, `BootstrapFewShot`,
  random search), instruction evolution (`COPRO`, `SIMBA`, `MIPROv2`, and
  `GEPA` with text feedback), ensembles and `BetterTogether`, and
  weight-level training with `BootstrapFinetune`, `GRPO`, and local MLX
  fine-tuning. They all use one `Imp.optimize` shape, and your metric on
  held-out data gates every one of them.
- **Beyond prompts**: Optimize-Anything points the same machinery at
  arbitrary text artifacts such as code, configs, and heuristics. It works
  anywhere you can score a candidate.

You will use one or two of these; the rest are there when a task earns them.

Then you run the program where it belongs. On the BEAM, a model call is one
more slow, fallible, concurrent effect, and supervising effects like that is
what the runtime was built for. Compiled programs persist as checksummed
artifacts with no secrets inside, and credentials bind at runtime. Execution
runs in bounded, supervised workers that return overloads instead of
hanging. Every call, retry, and tool step emits telemetry you can ship to
your metrics system. The [deployment example](examples/deployment) is a
complete OTP application.

Imp is a native BEAM realization of [DSPy](https://dspy.ai)'s research
program of programming language models instead of prompting them. Imp tracks
DSPy 3.2.1, and executable differential tests verify the optimizers against
that pinned upstream source, so "faithful port" is a claim you can run
yourself ([conformance report](docs/CONFORMANCE.md)). Where the BEAM offers
more, such as supervision and cheap concurrency, Imp uses it. See
[Imp for DSPy users](docs/IMP_FOR_DSPY_USERS.md) for exactly what differs.

## Install

Add the release to your `mix.exs` deps:

```elixir
{:imp, github: "deepfates/imp", tag: "v0.1.0"}
```

Imp is not on Hex yet; a Hex release is planned. You will need an API key
for a model provider (any [ReqLLM](https://hex.pm/packages/req_llm)
provider works; the docs use OpenAI).

## Learn

- **[Learning Path](docs/LEARNING_PATH.md)**: one router grown step by step,
  from the first live call through testing without a provider, metrics,
  optimization, tools, retrieval, persistence, and deployment.
- **[Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md)**: the full
  experiment, with the numbers and costs above.
- **[Livebooks](livebooks/)**: the same path as runnable notebooks.
- Reference: [API Guide](docs/API_GUIDE.md), [Glossary](docs/GLOSSARY.md),
  [Architecture](docs/ARCHITECTURE.md), and
  [Production Operations](docs/PRODUCTION_OPERATIONS.md).

## Where this is going

The near roadmap has three parts. First, a Hex release. Second, an
interactive-fiction environment package, where an optimizer teaches an
agent to survive a classic dungeon and every episode is recorded as a
replayable, branchable log. Third, the longer bet that belongs to this
runtime: optimization as a resident process, meaning programs that improve
from their own recorded history, under supervision, while they run.

# Imp

Program your LMs on the BEAM.

Let's build a support-ticket router: it reads a ticket and assigns a team and
an urgency. Add `{:imp, github: "deepfates/imp", tag: "v0.1.0"}` to your deps,
put an OpenAI key in `OPENAI_API_KEY`, and declare the task:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

route =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to one team: billing, infrastructure, security, or product.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} =
  Imp.call(route, %{ticket: "Customers are seeing other users' invoices in the billing portal."})

Imp.get(prediction, :team)
#=> "security"

Imp.get(prediction, :urgency)
#=> "high"
```

That output is real (`gpt-5.4-mini`). The ticket sounds like a billing problem;
the model read it and routed it to security, and the enum types guarantee the
answer is one of your teams — not free text you have to parse.

There is no prompt string in that program. The signature declares the task; Imp
renders the messages, validates the model's output against the declared types,
and retries with the validation error when the model drifts. The program is an
ordinary Elixir value, so you can:

- **Evaluate it**: score it against labeled examples with a metric.
- **Optimize it**: the [Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md)
  takes this same router from 35% to 90% on held-out tickets, for about a cent
  and twenty seconds of model calls.
- **Swap the model**: the provider is a runtime dependency, not part of the task.
- **Ship it**: save and load programs without secrets, run them under OTP
  supervision, observe them with telemetry.

Start with the [Learning Path](docs/LEARNING_PATH.md) — first live call through
evaluation, optimization, tools, and deployment — or open the full
[manual](docs/README.md).

## Install

Install the v0.1.0 release from GitHub with
`{:imp, github: "deepfates/imp", tag: "v0.1.0"}` in your `mix.exs` deps.
Imp is not on Hex yet; a Hex release is planned. In a
source checkout, use `{:imp, path: "."}` while developing against the local
repository.

## Documentation

- [Learning Path](docs/LEARNING_PATH.md)
- [Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md)
- [API Guide](docs/API_GUIDE.md)
- [Production Operations](docs/PRODUCTION_OPERATIONS.md)
- [Glossary](docs/GLOSSARY.md)
- [Architecture](docs/ARCHITECTURE.md)

Imp is inspired by DSPy's goal of declarative, measurable LM programs, with
Elixir-native structs, behaviours, process-local configuration, supervision,
and telemetry.

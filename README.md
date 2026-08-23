# Imp

Imp is an Elixir framework that turns language-model behavior into a typed Elixir program
you can measure and run inside an ordinary OTP application. It brings the central idea of
[DSPy](https://dspy.ai)—improving programs from examples rather than hand-editing
prompts—to the BEAM.

Here, “typed” means required inputs are checked and model outputs are parsed
and validated against the signature before application code receives them.
For DSPy compatibility, a supplied input whose value disagrees with its
declared type produces a warning rather than rejecting the call; validate
untrusted application inputs before calling the program.

<!-- "Imp with cards", Le Grand Etteilla (public domain, via Wikimedia Commons) -->
<p align="center">
  <img src="assets/imp-with-cards.jpg" width="380"
       alt="An imp studies a hand of cards through a lens while a smaller imp springs from its tail.">
</p>

A hand-built ticket router usually mixes the task, output format, parser, and
validation in one call:

```elixir no_run
text =
  ReqLLM.Generation.generate_text!("openai:gpt-5.4-mini", """
  Route this ticket. Return only JSON with team and urgency.
  team must be billing, infrastructure, security, or product.
  urgency must be low, normal, or high.

  Ticket: A customer can open another user's invoice by changing the URL.
  """)

%{"team" => team, "urgency" => urgency} = Jason.decode!(text)
```

That works, but every caller must keep the prompt, parser, accepted values, and
error policy in sync. In Imp the same contract is one typed program:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

route =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to the team that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

{:ok, prediction} =
  Imp.call(route, %{
    ticket: "A customer can open another user's invoice by changing the URL."
  })

Imp.get(prediction, :team)
#=> "security"
```

The model handles the ambiguous part: this sounds like billing, but it is a
security problem. Imp handles the solid part: rendering the request, checking
the response against the declared types, and returning a prediction your code
can use without parsing prose.

## Start with one program and improve it only after you can measure it

An Imp program is an Elixir value. You can call it, compose it with other
programs, test it with a scripted model, evaluate it on labeled examples, and
pass it to an optimizer.

The usual path is:

1. Declare the task with a signature.
2. Call the program and inspect real outputs.
3. Define examples and a metric that reflect the behavior you need.
4. Keep separate training, selection, and test data.
5. Let an optimizer propose a better program.
6. Select on validation data, then evaluate the selected program once on test
   data.
7. Save the selected parameters and load them into trusted application code.

The [Learning Path](docs/LEARNING_PATH.md) grows the router above through that
whole sequence. Generated module documentation is the exhaustive API
reference; the guide explains the public calls needed for normal application
code.

## Imp programs fit ordinary Elixir applications

Single-call programs use `Imp.predict/2` or `Imp.chain_of_thought/2`. Larger
programs are normal structs implementing `Imp.Module`; named predictor
callbacks let the same optimizers improve one stage at a time.

The [deployment example](examples/deployment/README.md) is a complete
two-stage support pipeline. It selects a program from disjoint data, writes a
linked result and parameter artifact, loads the artifact in a fresh OS
process, serves concurrent calls from a supervised process, hot-reloads new
parameters, and contains crashes and timeouts.

Imp also includes typed tools, ReAct-family loops, retrieval, streaming,
recursive language-model programs, local and provider training boundaries,
and optimizers for examples, instructions, prompts and weights. You do not
need to adopt that whole surface at once. Start with a program and a metric;
reach for a more powerful optimizer or runtime shape when the task earns it.

The supported center is the `Imp` facade, signatures, adapters, evaluation,
static and ReqLLM execution, tools, telemetry, saving, and the deployment
pattern. Generated docs group optimizer implementations, parameter artifacts,
agent loops, training integrations, and addressable runs under **Experimental
optimizers and advanced workflows**. Those APIs are real and tested, but may
change before 1.0; evaluate them against your own task before making them an
application dependency.

## When Imp is a good fit

Use Imp when a model performs a real application task with an output contract
you can name and behavior you can measure: extraction, classification,
retrieval-augmented answers, multi-stage analysis, tool use, or a bounded agent
loop. It is especially useful when the program must be tested without a
provider, improved from examples, persisted without credentials, and operated
inside an OTP system.

Do not put deterministic application logic behind a model call. An optimizer
also cannot invent the product requirement: you still need representative
examples, a metric that rewards the behavior you want, and data kept out of
training and selection. Imp provides the program and optimization machinery;
your application owns its tools, authority, data, budgets, and promotion
decision.

## Install

Imp is not published to Hex. Install the private source release from its
immutable tag (GitHub credentials with access to the repository are required):

```elixir
{:imp, github: "deepfates/imp", tag: "v0.3.1"}
```

Use `{:imp, path: "path/to/imp"}` only while developing against a local
checkout. Imp requires Elixir `~> 1.19`. Commit your application's `mix.lock`;
the Git tag fixes Imp's source, while normal Mix constraints may otherwise
resolve newer compatible transitive versions. Version `0.3.1` contains the
breaking `0.3` changes from `0.2.1`; see the [release notes](RELEASE_NOTES.md)
when upgrading.

Imp uses [ReqLLM](https://hex.pm/packages/req_llm) for model providers. The
examples use OpenAI, but programs are not tied to that provider. You can run
the provider-free parts of the learning path and deployment example without
an API key.

## Read next

- [Learning Path](docs/LEARNING_PATH.md) — build one program from its first
  call through evaluation, optimization, persistence, and deployment.
- [Imp for DSPy users](docs/IMP_FOR_DSPY_USERS.md) — map familiar DSPy
  concepts to Imp and understand the intentional BEAM differences.
- [Production Operations](docs/PRODUCTION_OPERATIONS.md) — credentials,
  telemetry, concurrency, persistence, and failure handling.
- [Runnable Livebooks](livebooks/01_real_lm_front_door.livemd) — inspect the
  same progression in IEx-ready notebooks.

Run `mix docs` for the exhaustive module and function reference.

Imp follows DSPy's central idea—program the behavior you want and optimize it
from examples—in an Elixir system built around immutable values, explicit
effects, supervision, and concurrency.

# Imp

Imp is an Elixir framework that turns language-model behavior into a typed Elixir program
you can measure and run inside an ordinary OTP application. It brings the central idea of
[DSPy](https://dspy.ai)—improving programs from examples rather than hand-editing
prompts—to the BEAM.

Imp is for an Elixir team moving an LM feature from a promising prompt into a
production system it must improve and operate. The immediate project is not
"adopt an AI framework"; it is to make one model-dependent behavior measurable,
changeable, and safe to deploy without scattering prompt, parser, retry, and
evaluation logic through the application or adding a separate Python service.
If you only need one unmeasured model call, ReqLLM directly is usually the
simpler choice. Imp becomes useful when you have examples or production
corrections, a behavior you can score, and a reason to retain and operate the
improved result inside OTP.

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
whole sequence. The [API Guide](docs/API_GUIDE.md) explains the concepts and
shows the public calls for normal application code.

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

## Install

Imp is not yet published to Hex. Use a source checkout for now:

```elixir
{:imp, path: "path/to/imp"}
```

`main` is an unpublished `0.3.0` internal candidate with breaking changes from
`0.2.1`, so pin an exact commit when another project depends on it. Tagging and
Hex publication remain explicit owner actions.

Imp uses [ReqLLM](https://hex.pm/packages/req_llm) for model providers. The
examples use OpenAI, but programs are not tied to that provider. You can run
the provider-free parts of the learning path and deployment example without
an API key.

## What the current evidence says

The core program, evaluation, selection, Artifact, restart, and concurrent OTP
serving path is exercised from an unpacked package, with failures retained as
data instead of hidden. Task-scoped studies include positive held-out TREC
results and honest negative or underpowered outcomes elsewhere; they do not
establish broad optimizer effectiveness, and optimizer modules remain
experimental before 1.0. The source repository's
[evidence guide](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md)
contains the contracts, exact results, withdrawn interpretation, and remaining
research gaps.

## Read next

- [Learning Path](docs/LEARNING_PATH.md) — build one program from first call
  through evaluation, optimization, tools, persistence, and deployment.
- [API Guide](docs/API_GUIDE.md) — understand signatures, programs, metrics,
  optimizers, experiments, artifacts, and the
  [signature type DSL](docs/API_GUIDE.md#signature-type-dsl), including why
  adapter prompts use [DSPy-compatible wire-format wording](docs/API_GUIDE.md#adapter-wire-format-wording).
- [Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md) — a complete
  measured optimization example with real outputs and costs.
- [TREC optimizer case study](docs/CASE_STUDY_TREC.md) — the strongest matched
  result, its limitations, and the exact provider-free recomputation command.
- [Imp for DSPy users](docs/IMP_FOR_DSPY_USERS.md) — map familiar DSPy
  concepts to Imp and see the intentional BEAM differences.
- [Production Operations](docs/PRODUCTION_OPERATIONS.md) — credentials,
  telemetry, concurrency, and failure handling.
- [Manual](docs/README.md) — every guide and runnable Livebook.

Imp follows DSPy's central idea—program the behavior you want and optimize it
from examples—in an Elixir system built around immutable values, explicit
effects, supervision, and concurrency.

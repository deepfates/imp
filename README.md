# Imp

Imp is [DSPy](https://dspy.ai) for the BEAM. You describe a language-model
task as a typed Elixir program, measure how it behaves, improve it from data,
and run the selected program inside an ordinary OTP application.

<!-- "Imp with cards", Le Grand Etteilla (public domain, via Wikimedia Commons) -->
<p align="center">
  <img src="assets/imp-with-cards.jpg" width="380"
       alt="An imp studies a hand of cards through a lens while a smaller imp springs from its tail.">
</p>

Here is a support-ticket router. The signature names the input, the two
outputs, and the values the model is allowed to return.

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

The core program, evaluation, experiment, artifact, and OTP deployment path is
exercised from an unpacked package, real providers, and fresh OS processes. All
optimizer modules remain experimental while their mechanisms and usefulness are
reviewed family by family before 1.0.

Existing results are deliberately narrow and mixed. A frozen TREC comparison
found positive held-out gains for GEPA and MIPROv2 on one task. A structured
Optimize Anything retry-policy condition improved new executable cases in two
of three seeds. Two modeled-MIPRO Banking77 conditions and one JSON-GEPA
HotPotQA condition completed their real multi-stage Artifact and fresh-service
lifecycles but missed their preregistered mean-lift bars. The earlier Imp
IFBench effectiveness interpretation is invalid because its optimization-time
scorer was wrong; the repaired source-exact scorer makes a new comparison
valid, but does not rehabilitate the old result. These outcomes show that the
product can optimize, select, persist, and serve honestly; they do not establish
broad optimizer effectiveness. The next research milestone is a matched
current-model Imp-versus-DSPy table across the official six-task GEPA suite.
Its one-seed matched `4096`-token baseline row is complete. A separately
completed source-sized `16384`-token IFBench denominator now scores Imp
`0.7619047619` and DSPy `0.7874149660`; this is runtime and measurement
evidence, not optimizer effectiveness or a general superiority result. Imp now
has a source-authenticated merge-enabled GEPA profile matching current DSPy's
public treatment shape. A one-seed engineering rehearsal has since
completed both optimizers end to end at the benchmark authors' own settings
(16384 output tokens, ~1/3-paper optimizer budget), establishing that the
machinery and its cost hold at that scale; by its own preregistration it
establishes nothing about optimizer effectiveness, and no parity or lift
conclusion is drawn from it. See [docs/EVIDENCE.md](docs/EVIDENCE.md). The scale and spend for the broader GEPA/MIPROv2 table
remain a later decision. This is an adapted
current-model comparison using official task families and metrics, not an exact
historical GEPA paper reproduction or a success-gated task search.
The complementary Grue stateful-agent condition has now completed the real
optimizer, Artifact, fresh-restart, and concurrent OTP lifecycle; its three
fixed local-model seeds all retained baseline with zero causal lift, so it is a
product-path proof and an honest narrow scientific negative rather than a
usefulness result.

## Read next

- [Learning Path](docs/LEARNING_PATH.md) — build one program from first call
  through evaluation, optimization, tools, persistence, and deployment.
- [API Guide](docs/API_GUIDE.md) — understand signatures, programs, metrics,
  optimizers, experiments, and artifacts.
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

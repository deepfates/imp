# Imp

Imp is an Elixir framework that turns language-model behavior into a typed Elixir program
you can measure, improve from examples, and run inside an
ordinary OTP application. It brings the central idea of
[DSPy](https://dspy.ai)—programming behavior and improving it from examples
rather than hand-editing prompts—to the BEAM.

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

The [deployment example](https://github.com/deepfates/imp/blob/main/examples/deployment/README.md) is a complete
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

Add Imp to your dependencies in `mix.exs`:

```elixir
{:imp, "~> 0.5"}
```

Imp requires Elixir `~> 1.19` on macOS or Linux. Every dependency comes from
Hex. One of them, erlexec, builds a small C++ program, so the machine that
compiles Imp needs a C++ compiler (the Xcode command line tools, or `g++`).
Version `0.5.0` changes how Imp is installed and one `Imp.MCP.OAuth` option;
see the
[release notes](RELEASE_NOTES.md) when upgrading from `0.4.0`.

ExMCP and erlexec are declared `runtime: false`: ordinary Imp startup does not
start them. An OTP release that uses `Imp.ACP` or `Imp.MCP` lists them in
`:load` mode, so they are bundled and started only when a protocol entry point
needs them:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.19",
    deps: [{:imp, "~> 0.5"}],
    releases: [
      my_app: [
        applications: [ex_mcp: :load, erlexec: :load]
      ]
    ]
  ]
end
```

Without `erlexec: :load`, the first stdio MCP connection in the release fails
with `{:spawn_failed, {:erlexec, ...}}`. See
[protocol runtime in releases](docs/PRODUCTION_OPERATIONS.md#protocol-runtime-in-releases).

`mix hex.audit` in a project that depends on Imp reports two advisories against
cowlib, which arrives through ExMCP's HTTP server. Neither has a fixed cowlib
release. EEF-CVE-2026-43966 (response splitting) is fixed one layer up, in
cowboy 2.16.0 and later (a fresh `mix deps.get` resolves 2.19.0), which
refuses header values containing CR or LF.
EEF-CVE-2026-43969 is in cowlib's client-side Cookie encoder, which nothing in
Imp's dependency tree calls. Imp's own gate ignores both, with what was
checked, in
[`.audit_ignore`](https://github.com/deepfates/imp/blob/main/.audit_ignore).

Imp is MIT licensed (`LICENSE`); `NOTICE` records the upstream DSPy code two
modules are ported from.

Imp uses [ReqLLM](https://hex.pm/packages/req_llm) for model providers. The
examples use OpenAI, but programs are not tied to that provider. The
[provider-free ticket router](https://github.com/deepfates/imp/blob/main/examples/provider_free_ticket_router/README.md)
runs a complete evaluation-and-optimization path without an API key; the
provider-free parts of the learning path and deployment example do too.

## Connect tools or expose a program

`Imp.MCP.connect/2` imports authorized MCP servers through ExMCP, returning
ordinary tools plus explicit connection cleanup. Source server/tool identities,
schemas, and annotations remain in each tool's `metadata.mcp` even when names
are qualified to avoid collisions. One unreachable server fails the whole
import by default; pass `on_failure: :drop` when the servers are independent,
and the import leaves the unreachable one out, names it in `unavailable` with
the position of its descriptor, and keeps the tools of the rest.

`Imp.ACP.start_link/1` and `Imp.ACP.run/1` expose an ordinary Imp program to
an ACP host. These are optional entry points, now included in Imp; consumers
no longer need the separate imp_acp package. Ordinary Imp startup starts no
protocol endpoint. See [protocol integration and migration](docs/PRODUCTION_OPERATIONS.md#protocol-integration-and-migration).

## Read next

- [Learning Path](docs/LEARNING_PATH.md) — build one program from its first
  call through evaluation, optimization, persistence, and deployment.
- [Imp for DSPy users](docs/IMP_FOR_DSPY_USERS.md) — map familiar DSPy
  concepts to Imp and understand the intentional BEAM differences.
- [Production Operations](docs/PRODUCTION_OPERATIONS.md) — credentials,
  telemetry, concurrency, persistence, failure handling, and the protocol
  adapters.
- [Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md) — score a router
  on held-out data, improve it with an optimizer, and prove the improvement on
  tickets it has never seen. About a cent to run yourself.
- [Runnable Livebooks](livebooks/01_real_lm_front_door.livemd) — inspect the
  same progression in IEx-ready notebooks.
- [Benchmarks](https://github.com/deepfates/imp/blob/main/docs/BENCHMARKS.md) — every number this repository publishes,
  the exact command that produces it, what that command costs you, and what
  cannot be re-measured at all. The numbers themselves are one row each in
  [benchmarks/RESULTS.md](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md).
- [Case study: GEPA and MIPROv2 on TREC](https://github.com/deepfates/imp/blob/main/docs/CASE_STUDY_TREC.md) — a matched
  optimizer comparison against pinned DSPy, recomputable from committed rows
  but not reproducible, and labeled that way.
- [Evidence](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md) —
  what kind of evidence stands behind which kind of claim, and the record of
  the runs that did not work.

Run `mix docs` for the exhaustive module and function reference.

For an ordinary ACP workspace agent with bounded tools, see
[examples/workspace_agent](https://github.com/deepfates/imp/blob/main/examples/workspace_agent/README.md). It depends
directly on this Imp checkout by path and includes a provider-free mode for
checking its launcher and workspace boundary.

## Where this fits

Imp is a library: typed language-model programs, an MCP client (`Imp.MCP`), and
the ACP server side (`Imp.ACP`). [ExMCP](https://hex.pm/packages/ex_mcp) is the
one MCP and ACP implementation Imp uses. Ordinary Imp startup opens no protocol
endpoint, and Imp is never a service. A host
application owns product lifetimes and decides when to launch an Imp program as
an external ACP process.

# Learning Path

Let's build a support-ticket router and grow it, step by step, into a
measured, tested, deployable program. Every section is a small change to code
you have already run. You need an OpenAI key in `OPENAI_API_KEY`; a full pass
through this page costs a few cents of model calls with `gpt-5.4-mini`.

## 1. Make A Real Call

Declare the task as a signature — named inputs, named outputs, types — and run
it as a program. There is no prompt string to maintain; Imp renders the
messages from the declaration and validates the model's output against it.

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

router =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to one team: billing, infrastructure, security, or product.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

{:ok, prediction} =
  Imp.call(router, %{ticket: "A customer noticed they can open other users' invoices by changing the number in the URL."})

Imp.get(prediction, :team)
#=> "security"
```

The enums guarantee the answer is one of your teams. When the model returns
anything else, Imp rejects it against the declared type and retries once with
the validation error (`json_retries: 1`) instead of handing you free text.

## 2. Measure Before Changing It

Before touching the program, give it a number. An example is a row of named
data; a metric scores a prediction against it. `Imp.evaluate/4` applies the
metric across a data set and returns the aggregate plus per-example rows.
Four live calls cost a fraction of a cent:

```elixir
devset =
  [
    Imp.example(ticket: "We were charged twice for the March invoice.", team: "billing"),
    Imp.example(ticket: "The API is returning 502 errors intermittently.", team: "infrastructure"),
    Imp.example(ticket: "A former employee still has access to our workspace.", team: "security"),
    Imp.example(ticket: "Can you add a dark mode to the dashboard?", team: "product")
  ]
  |> Enum.map(&Imp.with_inputs(&1, :ticket))

report = Imp.evaluate(router, devset, Imp.exact_match(:team), max_concurrency: 4, timeout: 60_000)
report.score
#=> 1.0
```

Four obvious tickets score 1.0 — that tells you the wiring works, not that the
router is good. Inspect `report.rows` when the aggregate does not explain a
result, and keep a held-out set for any decision that matters. When exact
match is not your product requirement, pass a two- or three-arity function
that returns a boolean, number, or structured score.

## 3. Improve With Measured Lift

An optimizer compiles your program into a better one, using training data and
your metric. The [Ticket Routing Tutorial](TUTORIAL_TICKET_ROUTING.md) runs
this workflow end to end on sixty labeled tickets, with a baseline, a
held-out score (30% to 85% in the committed runs, for about a cent), and a readable
diff of what changed. The shape is:

```elixir
compiled = Imp.optimize!(router, Imp.Optimizer.LabeledFewShot.new(k: 4), devset)
```

`LabeledFewShot` attaches labeled examples as demonstrations and costs
nothing to compile. (This line feeds it the four measurement examples just to
show the shape — in a real run, train on data you are not scoring against, as
the tutorial does.) Search optimizers — `RandomSearch`, `MIPROv2`, `GEPA` —
compare many candidate programs with the same metric. `RandomSearch` fits the
`Imp.optimize!/3` shape above; `MIPROv2` and `GEPA` also require a validation
set as a fourth argument (`Imp.optimize!/4`). They spend model calls, so they
cost dollars and take minutes, and the tutorial states both for its runs. An optimization counts
as an improvement when a held-out score shows it, and not before.

## 4. Test It Without A Provider

Your router now lives inside an application, and your test suite should not
call OpenAI. `Imp.LM.Static` is the test double: it plays the model's part by
returning the fields you script, while everything else — signature
validation, adapters, metrics — runs for real.

```elixir
lm =
  Imp.LM.Static.new(
    handler: fn _messages, _opts -> %{team: "security", urgency: "high"} end
  )

router =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to one team.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} =
  Imp.call(router, %{ticket: "A customer noticed they can open other users' invoices by changing the number in the URL."})

{Imp.get(prediction, :team), Imp.get(prediction, :urgency)}
#=> {"security", "high"}
```

The same trick proves your metric wiring before you spend provider calls on a
big evaluation — a scripted model that always answers `security` should score
exactly the fraction of examples labeled `security`:

```elixir
always_security =
  Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "security"} end)

program = Imp.predict("ticket -> team", lm: always_security)

devset =
  [
    Imp.example(ticket: "Refund the March invoice.", team: "billing"),
    Imp.example(ticket: "Suspicious login from a new device.", team: "security")
  ]
  |> Enum.map(&Imp.with_inputs(&1, :ticket))

Imp.evaluate(program, devset, Imp.exact_match(:team)).score
#=> 0.5
```

In application code, pass the LM to the program where the dependency should
be explicit, or use `Imp.context/2` for a request-scoped override — that is
also how tests swap in `Imp.LM.Static` without touching program definitions.

## 5. Give The Program Bounded Actions

ReAct is for tasks where the model must choose an action and observe its
result. An `Imp.Tool` is a named Elixir function; the tool policy is the
capability boundary, and the reserved `submit` tool validates the original
signature, so a tool loop cannot bypass the output contract. Here the router
also fetches the on-call engineer for the team it picks:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

on_call =
  Imp.tool(:on_call, "Look up the current on-call engineer for a team.", fn args ->
    team = to_string(args[:team] || args["team"]) |> String.downcase()

    %{
      "billing" => "Maya",
      "infrastructure" => "Tom",
      "security" => "Ines",
      "product" => "Raj"
    }[team] || "unknown"
  end,
    schema: %{
      "type" => "object",
      "properties" => %{
        "team" => %{"type" => "string", "enum" => ["billing", "infrastructure", "security", "product"]}
      },
      "required" => ["team"]
    }
  )

escalate =
  Imp.react(
    Imp.signature(
      "ticket -> team: enum[billing,infrastructure,security,product], contact: string",
      "First call the on_call tool with the team that owns the ticket. Then call submit with that team and the contact the tool returned."
    ),
    [on_call],
    lm: lm,
    tool_policy: [:on_call, :submit],
    max_iters: 4
  )

{:ok, prediction} = Imp.call(escalate, %{ticket: "Two-factor codes are not being accepted."})

{Imp.get(prediction, :team), Imp.get(prediction, :contact)}
#=> {"security", "Ines"}
```

Keep authorization, timeouts, and idempotency in the host application. Use
ReAct when the model needs to choose an action; call the Elixir function
directly when your code already knows the action.

## 6. Retrieve Context Deliberately

Retrieval supplies context the model cannot know; it does not replace
evaluation. `Imp.memory/2` is a deterministic in-memory retriever, and
`Imp.rag/3` retrieves, injects a context field, and records what it fetched
in the prediction metadata. Give the router your team charters and it can
apply conventions no model would guess — a gateway timeout is an
infrastructure problem here, even though it involves a refund:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

conventions = [
  %{id: "billing", text: "billing owns charges, refunds, invoices, and plan changes."},
  %{id: "infrastructure", text: "infrastructure owns outages, errors, and latency — including payment gateway failures and undelivered email."},
  %{id: "security", text: "security owns accounts, credentials, sessions, and data exposure."},
  %{id: "product", text: "product owns feature requests, how-to questions, and documentation."}
]

base =
  Imp.predict("ticket, context -> team: enum[billing,infrastructure,security,product]",
    lm: lm,
    adapter: Imp.Adapter.JSON,
    config: [json_retries: 1]
  )

routed = Imp.rag(base, Imp.memory(conventions, k: 2), k: 2, query_field: :ticket)

{:ok, prediction} = Imp.call(routed, %{ticket: "Refund attempts fail with a gateway timeout error."})

{Imp.get(prediction, :team), prediction.metadata.retrieval.count}
#=> {"infrastructure", 2}
```

For an external store, implement the `Imp.Retrieve` behaviour or pass a
two-argument function returning `{:ok, docs}`. Evaluate retrieval and answer
quality together, including cases where the relevant document is missing.

## 7. When The Input Outgrows The Prompt, Give The Model A Sandbox

RLM gives a controller model a constrained, budgeted Elixir environment —
safe evaluation, sub-model calls, bounded recursion, and a final `submit/1`
that still validates your signature. It is the tool for exploring or
computing over inputs too large or too structured for one prompt, not a
synonym for retrieval. [Livebook 04](../livebooks/04_tools_agents_mcp_rlm.livemd)
runs it live; set budgets before exposing production data and read the
redacted trace before raising them.

## 8. Persist Programs Or Selected Parameters, Not Secrets

There are two restart paths. A portable program — including one a few-shot
optimizer compiled — round-trips through `Imp.save!/2` and `Imp.load!/1` as a
checksummed JSON artifact. Credentials are never persisted: rebind the live
model at load time with `Imp.with_lm/2` or a scoped `Imp.context/2`. Saving a
program pinned to a non-portable runtime LM fails loudly instead of silently
dropping the pin.

```elixir
lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "security"} end)

path = Path.join(System.tmp_dir!(), "ticket-router-#{System.unique_integer([:positive])}.json")

try do
  router = Imp.predict("ticket -> team")
  :ok = Imp.save!(router, path)
  loaded = Imp.load!(path)

  {:ok, prediction} =
    Imp.context([lm: lm], fn ->
      Imp.call(loaded, %{ticket: "Suspicious login from a new device."})
    end)

  Imp.get(prediction, :team)
after
  File.rm(path)
end
#=> "security"
```

GEPA, MIPROv2, and SIMBA also support consumer-defined program graphs and live
runtime clients that should not be serialized. The shared parameter-artifact
lifecycle is executable with an ordinary optimized program:

```elixir
lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "security"} end)
base = Imp.predict("ticket -> team", lm: lm)

trainset = [
  Imp.example(ticket: "Suspicious login", team: "security")
  |> Imp.with_inputs(:ticket)
]

selected =
  Imp.optimize!(base, Imp.Optimizer.LabeledFewShot.new(k: 1), trainset)

artifact =
  Imp.Optimizer.Artifact.from_optimized_program(selected,
    artifact_id: "ticket-router-v1"
  )

path =
  Path.join(
    System.tmp_dir!(),
    "ticket-router-parameters-#{System.unique_integer([:positive])}.json"
  )

try do
  :ok = Imp.Optimizer.Artifact.write!(artifact, path)

  # Rebuild trusted code and runtime clients before applying saved parameters.
  fresh_router = Imp.predict("ticket -> team", lm: lm)

  deployed =
    path
    |> Imp.Optimizer.Artifact.read!()
    |> Imp.Optimizer.Artifact.apply(fresh_router)

  %Imp.Optimizer.Report{} = Imp.Optimizer.Report.fetch(deployed)
  report = Imp.Optimizer.Report.fetch(deployed)
  {:ok, prediction} = Imp.call(deployed, %{ticket: "Suspicious login"})
  {Imp.get(prediction, :team), report.optimizer}
after
  File.rm(path)
end
#=> {"security", :labeled_few_shot}
```

The parameter artifact carries named predictor signatures, demonstrations,
configs, and the canonical optimizer report. It does not carry your module,
LMs, adapters, callbacks, credentials, or arbitrary runtime state. Applying it
requires the fresh program to expose the same compatible named predictors; a
mismatch fails instead of partially installing state. GEPA can produce the
selected program, report, and artifact together with
`Imp.Optimizer.GEPA.compile_with_artifact/5`; MIPROv2 and SIMBA use the shared
`from_optimized_program/2` path demonstrated above after their own separate
train and validation evaluation. The [API Guide](API_GUIDE.md#optimize-a-program)
shows both forms. Repository-only research case studies for
[GEPA](https://github.com/deepfates/imp/tree/main/examples/local_gepa_banking77),
[MIPROv2](https://github.com/deepfates/imp/tree/main/examples/local_mipro_banking77),
and [SIMBA](https://github.com/deepfates/imp/tree/main/examples/local_simba_banking77)
exercise the save/apply/restart lifecycle with real model runtimes; they are
not part of the packaged teaching surface.

Treat either artifact as deployable program state: review and version it
alongside the metric and evaluation data that justified promoting it. Artifact
reproduction proves deployment behavior, not held-out improvement; measure the
selected program on data unavailable to optimization before making that claim.

## 9. Inspect Runtime Behavior

`Imp.trace/2` captures selected redacted telemetry while a function runs, and
`Imp.Observability.status/1` gives bounded, redacted views of provider state.
Tool calls, retries, and model traffic all emit events you can forward to
your metrics system:

```elixir
on_call = Imp.tool(:on_call, "Look up the on-call engineer", fn %{team: "security"} -> "Ines" end)

trace =
  Imp.trace(fn ->
    Imp.Tool.call(on_call, %{team: "security"})
  end)

{trace.result, Enum.map(trace.events, &elem(&1, 0))}
#=> {"Ines", [[:imp, :tool, :start], [:imp, :tool, :stop]]}
```

Telemetry is an observation boundary, not an authorization boundary. Keep
redaction on unless you are debugging a controlled local input.

## 10. Deploy The Verified Artifact

The `examples/deployment` OTP application shows the production shape: it
loads a checksummed artifact during supervised startup, binds credentials
only at runtime, and executes requests in bounded `Task.Supervisor` workers,
returning overloads and timeouts instead of letting one slow provider call
block the program server.

Its provider-free `run_workflow.exs` is the capstone for this path: one command
declares and measures a typed two-predictor analysis → routing support
program, compiles and inspects selected
demonstrations, evaluates a disjoint test split, saves and hot-reloads the
checksummed parameter artifact onto the trusted reconstructed module, serves
concurrent calls, and proves a killed or timed-out
worker does not take down the server. The planted static LM makes those product
mechanics deterministic; its score is explicitly not real-model effectiveness.
The package gate repeats the saved selected program's load and call in a second
OS process against the unpacked artifact.

For your own deployment, keep the artifact path, model name, API key,
concurrency limits, and retry policy in runtime configuration. Evaluate the
candidate before promotion, rebind the live LM at startup, and watch status,
latency, validation errors, and cost after rollout.

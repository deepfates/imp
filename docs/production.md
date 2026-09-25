# Running Imp in production

An Imp program is a value. Your application decides which processes call
it, where its credentials come from, how long a call may take and what it may
cost. This page covers those decisions in the order you meet them: starting
Imp, credentials, concurrency, timeouts, cost and caching, persistence and
telemetry. The
[deployment example](https://github.com/deepfates/imp/tree/main/examples/deployment)
is a complete OTP application that puts them together.

## Imp in your supervision tree

Imp is an OTP application, and adding `{:imp, "~> 0.5"}` to your
dependencies starts it with yours. It supervises its settings, its response
cache and the task pools that bound its work. It opens no listener and
starts no subprocess, and the MCP and ACP runtimes start only when you use
them. In a script, `Mix.install([{:imp, "~> 0.5"}])` starts it too.

## Credentials at runtime

Read keys when the application starts, from the environment or your secret
store, and pass them to the model client:

~~~elixir
# config/runtime.exs
import Config

config :tickets, openai_api_key: System.fetch_env!("OPENAI_API_KEY")

# ReqLLM loads a .env file from the working directory by default.
config :req_llm, load_dotenv: false
~~~

Build the program once, with its model, and keep it where request processes
can read it:

```elixir
defmodule Tickets.Router do
  @moduledoc "Routes a support ticket to the squad that owns it."

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    :persistent_term.put(
      __MODULE__,
      build(Application.fetch_env!(:tickets, :openai_api_key))
    )

    :ignore
  end

  def build(api_key) do
    lm =
      Imp.req_llm("openai:gpt-5.4-mini",
        api_key: api_key,
        receive_timeout: 20_000,
        max_tokens: 200
      )

    "ticket -> team: enum[atlas,harbor,beacon,quill]"
    |> Imp.signature("Route the support ticket to the squad that owns it.")
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)
  end

  def route(ticket) do
    with {:ok, prediction} <-
           Imp.call(:persistent_term.get(__MODULE__), %{ticket: ticket}) do
      {:ok, Imp.get(prediction, :team)}
    end
  end
end
```

Saved programs and parameter artifacts never contain a key, so the same file
can move from a laptop to CI to production. Traces, telemetry and run events
redact common key names and key-shaped values. Treat model, retriever and
MCP URLs as trusted configuration: Imp does not restrict where they point.

## Concurrency

`Imp.call/2` runs in the calling process: the Phoenix request, the
GenServer callback, the job. A model call can take seconds, so do not make it
inside a process that serializes other work, such as a GenServer whose
mailbox other callers wait on. Run it in the request's own process, or in a
supervised task as the deployment example's `ProgramServer` does.

Two bounds apply:

- **Imp's own fan-out.** Everything Imp runs concurrently, from
  `Imp.parallel/3` and evaluation to optimizers and runs, shares one pool per
  node, sized by `Imp.configure(async_max_workers: n)` (8 by default). Work
  beyond it waits its turn.
- **Your callers.** How many requests may call a model at once is your
  application's decision. `Imp.start_run(program, inputs, admission: {pool,
  limit})` answers `{:error, :busy}` when a named pool is full; a
  `Task.Supervisor` with `max_children:` does the same for plain calls.

Size both to what your provider's rate limit allows.
[Runs and supervision](diving-deeper/runs-and-supervision.md) covers runs,
pools and cancellation.

## Timeouts

A model call has three layers of time limit:

1. **One attempt.** `receive_timeout:` on the client bounds how long one HTTP
   attempt waits for the provider. Defaults vary by provider and model, from
   30 seconds to several minutes for reasoning models, so set it.
2. **Retries.** ReqLLM retries a dropped or timed-out connection up to three
   times, immediately (`max_retries:` on the client). A model call changes
   nothing outside, so a retry is safe, but it multiplies the worst case.
3. **The whole call.** `Imp.Deadline.with_deadline/2` bounds everything
   inside it, retries and multi-step programs included. Every request made
   inside is cut to the time left:

~~~elixir
router = Tickets.Router.build(System.fetch_env!("OPENAI_API_KEY"))

Imp.Deadline.with_deadline(50, fn ->
  Imp.call(router, %{ticket: "Deploys hang at 90%."})
end)
#=> {:error, %ReqLLM.Error.API.Timeout{kind: :total, ...}}
~~~

To stop a call from outside, start it as a run and cancel it. Tool calls are
different from model calls: a tool that times out may already have acted,
and Imp never retries one (see
[Runs and supervision](diving-deeper/runs-and-supervision.md)).

## Cost and caching

`max_tokens:` on the client caps each answer. With `track_usage: true`, each
prediction records tokens and cost per model:

~~~elixir
Imp.context([track_usage: true], fn ->
  for _ <- 1..2 do
    {:ok, prediction} =
      Imp.call(router, %{ticket: "Our SSO login loops back to the sign-in page."})

    usage =
      prediction
      |> Imp.Prediction.get_lm_usage()
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:input_tokens, :output_tokens]))

    {Imp.get(prediction, :team), usage}
  end
end)
#=> [{"beacon", [%{input_tokens: 209, output_tokens: 10}]}, {"beacon", []}]
~~~

The second call cost nothing: it was an identical request, and Imp answered
it from its response cache. The cache is on by default for `Imp.req_llm/2`
clients. It lives in memory, keyed on the model, the messages and the
request options, and is empty after a restart. Identical requests get
identical answers, which is what you want for a classifier and not always
for a program that should vary. Turn it off for one client with
`cache: false`, or bound it with
`Imp.Cache.configure(ttl: :timer.hours(1), max_entries: 10_000)`.

For a hard spending ceiling, such as for an optimizer run, start a ledger
with `Imp.start_optimizer_budget/1` and wrap each model with
`Imp.budgeted_lm/3`: a call that could exceed the request, token or dollar
limit is refused before it is sent.

## Persistence

Ship what an optimizer chose as a reviewed file with your release. At
startup, build the program in code and apply the chosen parameters to it:

~~~elixir
artifact = Imp.Optimizer.Artifact.read!(artifact_path)
program = Imp.Optimizer.Artifact.apply(artifact, Tickets.Router.build(api_key))
~~~

`Imp.Optimizer.Artifact.apply/4` raises if the artifact does not fit the
program, so a bad file stops the release at boot, or, when reloading a
running service, leaves the current program serving.
[Saving and artifacts](diving-deeper/saving-and-artifacts.md) covers both
saved forms, and the deployment example reloads parameters while serving.

## Telemetry

Imp emits `:telemetry` events for every program call, model request, tool
call, evaluation and optimizer step, with credentials redacted from their
metadata. Attach a handler to forward them to your metrics:

```elixir
defmodule Tickets.ImpMetrics do
  require Logger

  def attach do
    :telemetry.attach_many(
      "tickets-imp",
      [[:imp, :module, :stop], [:imp, :lm, :stop]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event, %{duration: duration}, metadata, _config) do
    milliseconds = System.convert_time_unit(duration, :native, :millisecond)
    Logger.debug("#{inspect(event)} #{inspect(metadata[:result])} in #{milliseconds}ms")
  end
end

Tickets.ImpMetrics.attach()
#=> :ok

:telemetry.detach("tickets-imp")
#=> :ok
```

[Runs and supervision](diving-deeper/runs-and-supervision.md#telemetry)
lists the event families. `Imp.disable_logging/0` silences Imp's own log
messages without touching your application's log level.

## Releases that use MCP or ACP

Imp compiles against its protocol libraries but does not start them for
ordinary prediction, evaluation or optimization. A release that uses
`Imp.MCP` or `Imp.ACP` must bundle them without starting them at boot:

~~~elixir
# mix.exs
def project do
  [
    app: :tickets,
    releases: [tickets: [applications: [ex_mcp: :load, erlexec: :load]]]
  ]
end
~~~

An ACP agent speaks over standard output, so keep a release's logs on
standard error.

## The reference application

[`examples/deployment`](https://github.com/deepfates/imp/tree/main/examples/deployment)
is a small OTP application that loads a checksummed artifact at startup, reads its key
from the environment, serves calls from bounded supervised tasks, answers
overload and timeouts with errors instead of blocking, and reloads
parameters without a restart. Its `run_workflow.exs` runs the whole path
offline, from optimizing to serving.

[Livebook 05](../livebooks/05_operating_imp.livemd) runs the pieces of this
page in a notebook: bounded calls, redaction, saving without secrets,
telemetry, and a live check.

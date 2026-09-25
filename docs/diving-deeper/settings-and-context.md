# Settings and context

## Intent

A program needs a model and an adapter. There are three places they can come
from: the program itself (`lm:` when you build it), a scoped override
(`Imp.context/2`), and node-wide defaults (`Imp.configure/1`). This page
covers what each is for, which wins, and how settings reach the processes
Imp starts on your behalf.

Read it when you swap models for one request or test, wonder why a program
ignored a setting, or start your own processes around Imp calls.

## Design decisions

### 1. Pass `lm:` to the program

A program built with `lm:` answers with that model wherever it runs: in a
test, in another process, inside an optimizer, after it is saved and loaded.
An Elixir value should not change meaning with ambient state, and a program
that quietly uses whatever model its caller configured is hard to reason
about once several teams or tenants share a node. So the recommended style is
explicit, and the settings are defaults for programs built without one.

### 2. A program's own model wins

The order is: the model the program was built with, then `Imp.context/2`,
then `Imp.configure/1`. A context does not override a pinned program, so a
scoped override cannot redirect code that asked for a specific model. To run
a pinned program with a different model, make a new program with
`Imp.with_lm/2`.

### 3. `Imp.configure/1` sets node-wide defaults

`Imp.configure/1` writes to a settings process under Imp's supervision tree.
It is global to the node and mutable: every process sees the change. Call it
once when your application starts, not per request. Unlike DSPy's
`configure`, it may be called from any process.

### 4. `Imp.context/2` is scoped to one process and one function

`Imp.context(overrides, fun)` applies the overrides while `fun` runs in the
calling process and restores the previous settings when it returns or
raises. Contexts nest, the inner one winning. Because nothing global
changes, tests that use contexts can run with `async: true`.

### 5. Imp's own tasks carry your context; your processes do not

Settings live in the process dictionary, which a new process does not
inherit. Every task Imp starts, for `Imp.parallel/3`, evaluation rows,
optimizer fan-out and runs, captures the effective settings when the work is
submitted and applies them inside the task. A `Task.async/1` or `spawn/1` of
your own starts from the node-wide defaults, which is ordinary BEAM
behaviour. Capture what you need before you cross that boundary, or pass
`lm:` and avoid the question.

### 6. Model options belong to the model client

Temperature, token limits, timeouts and reasoning effort are options on the
client you pass as `lm:`, such as `Imp.req_llm/2`. Settings hold what applies
across models: which model and adapter are the defaults, how much work may
run at once, and whether to record usage.

### 7. There is no `callbacks` setting

Observation goes through `:telemetry`, which already lets any number of
handlers attach and detach. `Imp.configure(callbacks: ...)` raises rather
than accept a setting nothing would call.

## API walkthrough

### Which model answers

Scripted models that each answer with a different team make the precedence
visible:

```elixir
answering = fn team ->
  Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: team} end)
end

pinned = Imp.predict("ticket -> team", lm: answering.("atlas"))
unpinned = Imp.predict("ticket -> team")

team = fn program ->
  {:ok, prediction} = Imp.call(program, %{ticket: "We were charged twice this month."})
  Imp.get(prediction, :team)
end

Imp.configure(lm: answering.("harbor"))
{team.(pinned), team.(unpinned)}
#=> {"atlas", "harbor"}

Imp.context([lm: answering.("beacon")], fn -> {team.(pinned), team.(unpinned)} end)
#=> {"atlas", "beacon"}

team.(Imp.with_lm(pinned, answering.("quill")))
#=> "quill"
```

A program with no model anywhere returns an error rather than guessing:

```elixir
Imp.configure(lm: nil)
Imp.call(unpinned, %{ticket: "We were charged twice this month."})
#=> {:error, :lm_not_configured}
```

### How settings reach tasks

```elixir
Imp.context([lm: answering.("quill")], fn ->
  [{:ok, first}, {:ok, second}] =
    Imp.parallel(unpinned, [%{ticket: "one"}, %{ticket: "two"}])

  inherited = Imp.get(first, :team) == "quill" and Imp.get(second, :team) == "quill"

  plain_task_lm = Task.async(fn -> Imp.settings().lm end) |> Task.await()
  {inherited, plain_task_lm}
end)
#=> {true, nil}
```

`Imp.parallel/3` ran both calls with the context's model. The plain task saw
the node-wide default, which is no model at all.

### In an application

Build the model once at startup from runtime configuration and pass it to
the programs that use it. Set node-wide defaults in the same place, if you
use them:

```elixir
defmodule Tickets.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Imp.configure(async_max_workers: 16)

    Supervisor.start_link([Tickets.Router],
      strategy: :one_for_one,
      name: Tickets.Supervisor
    )
  end
end
```

[Running Imp in production](../production.md) shows the router module that
builds its program with an explicit model.

### What you can set

| Key | Default | Purpose |
|---|---|---|
| `lm` | `nil` | Model for programs built without `lm:`. |
| `adapter` | `Imp.Adapter.Chat` | Adapter for programs built without `adapter:`. |
| `async_max_workers` | `8` | Size of the node-wide pool all of Imp's tasks share. |
| `track_usage` | `false` | Record token counts and cost on each prediction (`Imp.Prediction.get_lm_usage/1`). |
| `warn_on_type_mismatch` | `true` | Log a warning when an input does not match its declared type. |

`two_step_extraction_lm` is the second model `Imp.Adapter.TwoStep` uses.
`Imp.configure/1` refuses any other key. `Imp.context/2` carries keys of your
own as given, to code that reads them with `Imp.settings/0`, but refuses
`:max_errors`, `:retriever` and `:callbacks` with a message saying where each
belongs: they are options of the optimizer, the program and telemetry. `Imp.settings/0` returns the
effective settings for the calling process.

## Cross-links

- [Runs and supervision](runs-and-supervision.md): the pool that
  `async_max_workers` sizes, and how runs carry settings into their tasks.
- [Saving and artifacts](saving-and-artifacts.md): saved programs keep a
  pinned model's settings but never its key.
- `Imp.Settings` documents the functions behind `Imp.configure/1` and
  `Imp.context/2`.

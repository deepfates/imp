# Runs and supervision

## Intent

`Imp.call/2` runs a program in the calling process and returns its answer.
That is enough for most code. When you need to watch a program while it
runs, stop it, limit how many run at once, or approve each tool call before it
happens, start it as a **run**: `Imp.start_run/3` runs the program as a
supervised task and gives you a handle to it.

This page is the BEAM side of Imp: which processes do the work, what bounds
them, what a timeout or a cancellation means, what Imp records when it
cannot know whether a tool acted, and how to observe all of it.

## Design decisions

### 1. A run is a supervised task tied to the process that started it

The run's task lives under Imp's task supervisor and is not linked to you,
so a crash inside the program comes back as a result instead of taking your
process down. It is monitored in the other direction: when the process that
started the run dies, Imp cancels the run's work in flight and ends the
task. Model calls and tool calls do not outlive the process that asked for
them, and nothing keeps spending after it has gone.

### 2. All of Imp's work shares one bounded pool

Every task Imp starts, from `Imp.parallel/3` and evaluation rows to
optimizer fan-out and runs, takes a place in one pool per node, sized by the
`async_max_workers` setting (8 by default). When the pool is full, new work
waits its turn instead of failing. Provider rate limits and memory are
per-node, so the bound is too. Fan-out that Imp runs inside one of its own
tasks uses that task's place, so nested work cannot deadlock the pool, even
with a limit of one.

### 3. A host can name its own pools

`admission: {pool, limit}` counts a run in a pool you name, such as one per
customer or per agent, instead of the shared one. A full named pool answers
`{:error, :busy}` at once rather than queueing, because the host knows better
than Imp whether to wait, shed or retry.

### 4. Events are a record, not a transaction

A run emits ordered, redacted events: the run starting and ending, each model
request and response, each tool call and result. An `event_sink:` function
receives them in order from one delivery process, so a slow sink delays only
its own later events, never cancellation. If the sink fails, the process
that started the run is told which event the sink was holding and which it
never received. Events live in memory until you store them, so a node that
dies loses what was not stored: to require a record *before* an effect,
write it in the authorization callback.

### 5. Tool calls are authorized at the effect, per run

`authorize:` is a function Imp calls before each ReActV2 or RLM tool call,
after the call has passed the program's tool policy and the tool's argument
schema. It returns `:allow`, `{:deny, reason}` or `{:cancel, reason}`. A
denial becomes an observation the model reads and can respond to. A callback
that crashes, times out (`authorization_timeout:`, 30 seconds by default) or
answers anything else denies. The decision belongs to the run, not the
program, because the same program serves users with different permissions. A
program that cannot ask fails closed: an `authorize:` run of a module
without authorization support returns an error instead of running tools
unasked.

### 6. "I do not know" is an outcome

When a tool raises, exits or times out, it may already have done what it was
asked. A timeout does not say whether a refund was issued or a message sent.
So Imp records that call's outcome as `:unknown`, not as a failure that
implies nothing happened, and never retries a tool call on its own: retrying
an unknown write can do it twice. The outcomes are `:result`, `:refused` and
`:auth_refused` (nothing ran), `:not_sent` (the request never left) and
`:unknown`. `Imp.Tool.outcome/1` reads one; each `:tool_result` event carries
it as `metadata.outcome`. Model calls are different: they change nothing
outside, so the model client may retry a dropped connection.

### 7. Cancelling stops Imp's work; it does not undo the world

Cancelling a run calls the cancellation of each operation in flight, then
ends the task. A remote write that was already sent may still land.
Cancellation says what Imp stopped, never what did not happen.

### 8. Telemetry observes; it never steers

Imp emits `:telemetry` events for modules, model calls, tools, retrievers,
evaluation and optimizers, with metadata redacted before any handler sees
it. A handler that raises is detached by `:telemetry` and the program runs
on. There is no `callbacks:` setting; `Imp.configure/1` refuses one, so that
nothing appears to observe calls it does not.

## API walkthrough

The examples use scripted models so they run offline.

### Start a run and read its events

```elixir
lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end)
router = Imp.predict("ticket -> team: enum[atlas,harbor,beacon,quill]", lm: lm)

{:ok, run} = Imp.start_run(router, %{ticket: "We were charged twice this month."})
{:ok, prediction} = Task.await(run.task)
events = Imp.Run.events(run)
:ok = Imp.Run.stop(run)

{Imp.get(prediction, :team), Enum.map(events, & &1.kind)}
#=> {"atlas", [:run_started, :model_request, :model_response, :run_finished]}
```

`run.task` is an ordinary `Task`. `Imp.Run.events/1` returns what the run
has kept; `Imp.Run.stop/1` releases the run's control process when you are
done with it. `Imp.Run.Event.kinds/0` lists every kind, and
`Imp.Run.Event.to_map/1` turns an event into redacted JSON-safe data for
storage.

### Timeouts and cancellation

A run has no timeout of its own; you decide how long to wait and what to do
then:

```elixir
slow =
  Imp.LM.Static.new(
    handler: fn _messages, _opts -> Process.sleep(5_000) && %{team: "atlas"} end
  )

{:ok, run} =
  Imp.start_run(Imp.predict("ticket -> team", lm: slow), %{ticket: "Charged twice."})

Task.yield(run.task, 100)
#=> nil

{:ok, events} = Imp.Run.cancel_with_events(run, :too_slow, 1_000)
{Enum.map(events, & &1.kind), List.last(events).error}
#=> {[:run_started, :model_request, :run_cancelled], :too_slow}
```

`Imp.cancel_run/3` does the same and returns `:ok`. The second argument is
the reason recorded on `:run_cancelled`; the third bounds how long each
cancellation may take before Imp gives up on it and kills the task.

### Admission pools

```elixir
slow =
  Imp.LM.Static.new(
    handler: fn _messages, _opts -> Process.sleep(200) && %{team: "atlas"} end
  )

slow_router = Imp.predict("ticket -> team", lm: slow)

{:ok, first} =
  Imp.start_run(slow_router, %{ticket: "one"}, admission: {{:tenant, 42}, 1})

Imp.start_run(slow_router, %{ticket: "two"}, admission: {{:tenant, 42}, 1})
#=> {:error, :busy}

{:ok, _prediction} = Task.await(first.task)
:ok = Imp.Run.stop(first)
```

A run in a named pool does not count against the shared pool. Work the run
starts inside itself does.

### Authorizing tool calls

An agent that may refund a charge, with a rule that refunds over ten dollars
need a person. The scripted model asks for a refund, then submits a reply:

```elixir
{:ok, turn} = Agent.start_link(fn -> 0 end)

agent_lm =
  Imp.LM.Static.new(
    handler: fn _messages, _opts ->
      case Agent.get_and_update(turn, &{&1, &1 + 1}) do
        0 ->
          %{
            tool_calls: [
              %{
                id: "call-1",
                name: "refund",
                arguments: %{"ticket_id" => "T-1042", "amount_cents" => 1299}
              }
            ]
          }

        _ ->
          %{
            tool_calls: [
              %{
                id: "call-2",
                name: "submit",
                arguments: %{
                  "reply" => "A person will review the refund.",
                  "refunded" => false
                }
              }
            ]
          }
      end
    end
  )

refund =
  Imp.tool(:refund, "Refund a charge on a ticket.", fn _args -> "refunded" end,
    schema: %{
      "type" => "object",
      "required" => ["ticket_id", "amount_cents"],
      "properties" => %{
        "ticket_id" => %{"type" => "string"},
        "amount_cents" => %{"type" => "integer"}
      }
    }
  )

agent =
  Imp.react("ticket -> reply, refunded: bool", [refund], lm: agent_lm, max_iters: 3)

{:ok, run} =
  Imp.start_run(agent, %{ticket: "I was charged twice for T-1042."},
    authorize: fn request ->
      if request.tool_name == :refund and request.arguments["amount_cents"] > 1000,
        do: {:deny, :needs_a_person},
        else: :allow
    end
  )

{:ok, prediction} = Task.await(run.task)

tool_results =
  for event <- Imp.Run.events(run),
      event.kind == :tool_result,
      do: {event.tool_name, event.metadata.outcome}

:ok = Imp.Run.stop(run)

{Imp.get(prediction, :reply), tool_results}
#=> {"A person will review the refund.", [{"refund", :refused}, {"submit", :result}]}
```

The callback receives an `Imp.Execution.Authorization` with the run id, the
tool call id, the tool name and the validated arguments. Calls that fail the
schema never reach it.

### Unknown outcomes

The same agent with a refund tool whose connection drops mid-call:

```elixir
:ok = Agent.update(turn, fn _ -> 0 end)

flaky_refund =
  Imp.tool(:refund, "Refund a charge on a ticket.", fn _args ->
    exit(:connection_closed)
  end)

agent =
  Imp.react("ticket -> reply, refunded: bool", [flaky_refund],
    lm: agent_lm,
    max_iters: 3
  )

{:ok, run} = Imp.start_run(agent, %{ticket: "I was charged twice for T-1042."})
{:ok, _prediction} = Task.await(run.task)

[refund_result | _] =
  for event <- Imp.Run.events(run), event.kind == :tool_result, do: event

:ok = Imp.Run.stop(run)

{refund_result.metadata.outcome, refund_result.error}
#=> {:unknown, {:error, {:tool_error, :refund, {:exit, :connection_closed}}}}
```

Before retrying, find out whether the refund went through: ask the payment
system, or give the tool an idempotency key it can check.

### Event sinks and capture limits

```elixir
parent = self()

{:ok, run} =
  Imp.start_run(router, %{ticket: "Webhooks stopped arriving at 3am."},
    event_sink: fn event -> send(parent, {:imp_event, event.sequence, event.kind}) end
  )

{:ok, _prediction} = Task.await(run.task)
:ok = Imp.Run.stop(run)

for _ <- 1..4, do: receive(do: ({:imp_event, sequence, kind} -> {sequence, kind}))
#=> [{0, :run_started}, {1, :model_request}, {2, :model_response}, {3, :run_finished}]
```

`Imp.Run.stop/1` waits up to five seconds for the sink to finish. A sink
that raises, throws or exits sends the process that started the run
`{:imp_run_event_sink_failed, run_id, %{sequence: _, kind: _, reason: _}}`;
events it never received arrive as `{:imp_run_event_undelivered, run_id, _}`.
Capture is bounded: `max_event_bytes:` (64 KiB) replaces a larger event with
a digest and its size, and `max_events:` (512) and `max_snapshot_bytes:`
(4 MiB) bound what `Imp.Run.events/1` keeps, marking evictions with a
`:capture_gap` event. The sink sees every bounded event. Set all three to
`:infinity` to keep a complete record in memory.

### Exporting a run

`Imp.Trajectory.to_atif/2` turns a run's events, or the stored maps of them,
into an [ATIF](https://www.harborframework.com/docs/agents/trajectory-format)
v1.8 trajectory, a JSON format for agent runs that other tools can read:

```elixir
{:ok, run} = Imp.start_run(router, %{ticket: "We were charged twice this month."})
{:ok, _prediction} = Task.await(run.task)

trajectory =
  Imp.Trajectory.to_atif(Imp.Run.events(run),
    agent: %{name: "ticket-router", version: "1"}
  )

:ok = Imp.Run.stop(run)

{trajectory["schema_version"], Enum.map(trajectory["steps"], & &1["source"])}
#=> {"ATIF-v1.8", ["system", "user", "agent"]}
```

The native events stay the source of truth: they keep order, lifecycle and
outcomes that the export summarizes. An unknown outcome, a missing call or a
capture gap stays visible in the export rather than being filled in.

### Telemetry

Event families, each with `:start`, `:stop` and `:exception` unless noted:

- `[:imp, :module, ...]`: one program call.
- `[:imp, :lm, ...]`: one model request, plus `[:imp, :lm, :stream, :start | :chunk | :stop]`.
- `[:imp, :tool, ...]` and `[:imp, :retriever, ...]`.
- `[:imp, :evaluate, ...]` and `[:imp, :optimizer, ...]`, plus
  `[:imp, :optimizer, :trial, ...]` for candidate evaluations and
  `[:imp, :optimizer, :progress]` for GEPA generations.
- `[:imp, :adapter, :parse, :retry | :error]` when a model's answer does not parse.
- `[:imp, :cache, :hit | :miss]` and the cache's coalescing events.

Every span carries a `:call_id`, and a nested span its parent's
`:parent_call_id`, across Imp's task boundaries, so one request's model,
tool and module events can be put back together. `Imp.trace/2` captures
events around one function without attaching handlers yourself:

```elixir
trace =
  Imp.trace(fn -> Imp.call(router, %{ticket: "Charged twice."}) end,
    events: [[:imp, :module, :stop]]
  )

for {event, _measurements, metadata} <- trace.events,
    do: {event, metadata.module, metadata.result}
#=> [{[:imp, :module, :stop], Imp.Predict, :ok}]
```

For long optimizer runs, `Imp.subscribe_optimizer_progress/1` sends progress
messages to a process of your choosing.

## Cross-links

- [Settings and context](settings-and-context.md): how settings, including
  `async_max_workers`, reach a run's task.
- [Running Imp in production](../production.md): serving calls with bounded
  concurrency and timeouts, and forwarding telemetry.
- [Metrics and evaluation](metrics-and-evaluation.md): evaluation rows run in
  the same pool.
- `Imp.Run`, `Imp.Run.Event`, `Imp.Execution.Authorization`, `Imp.Tool`
  and `Imp.Telemetry` list every option.

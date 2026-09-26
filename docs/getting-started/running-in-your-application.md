# Running it in your application

A model call is slow, sometimes very slow, and sometimes it fails. In an
application we want three things from the code that makes it: a bound on how
long any one call may take, a bound on how many run at once, and the
certainty that one bad call can't take anything else down. OTP gives us all
three, and an Imp program, being an immutable value, needs nothing special to
use them.

Here is a small server for the router. It holds the current program and runs
each call in its own supervised task:

```elixir
defmodule TicketRouter.Server do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def route(ticket, timeout \\ 15_000) do
    %{program: program, tasks: tasks} = GenServer.call(__MODULE__, :state)
    task = Task.Supervisor.async_nolink(tasks, fn -> Imp.call(program, %{ticket: ticket}) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, prediction}} -> {:ok, Imp.get(prediction, :team)}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  rescue
    RuntimeError -> {:error, :overloaded}
  end

  def put_program(program), do: GenServer.call(__MODULE__, {:put_program, program})

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}
  def handle_call({:put_program, program}, _from, state), do: {:reply, :ok, %{state | program: program}}
end
```

The server's own work is tiny: it hands out the current program and swaps in
a new one. The model call runs in a task the caller starts, so a slow request
never sits in the server's mailbox, and unrelated calls proceed in parallel.

- **Timeouts.** `Task.yield/2` waits at most `timeout`, then the task is
  killed and the caller gets `{:error, :timeout}`.
- **Bounded concurrency.** The task supervisor's `max_children` caps the calls
  in flight. Past the cap, `async_nolink` raises, and the caller gets
  `{:error, :overloaded}` at once instead of queueing behind everyone else.
- **Isolation.** `async_nolink` means a crash in a call is reported to that
  caller and goes no further.

Let's start it under a supervisor, with a scripted model standing in for the
provider:

```elixir
scripted = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end)

program =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(lm: scripted, adapter: Imp.Adapter.JSON)

children = [
  {Task.Supervisor, name: TicketRouter.Tasks, max_children: 8},
  {TicketRouter.Server, program: program, tasks: TicketRouter.Tasks}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

TicketRouter.Server.route("We were charged twice this month.")
#=> {:ok, "atlas"}
```

Now a model that never answers. The call gives up on time, and the server
goes on serving:

```elixir
stuck = Imp.LM.Static.new(handler: fn _messages, _opts -> Process.sleep(:infinity) end)
:ok = TicketRouter.Server.put_program(Imp.with_lm(program, stuck))

timed_out = TicketRouter.Server.route("We were charged twice this month.", 100)

:ok = TicketRouter.Server.put_program(program)
{timed_out, TicketRouter.Server.route("We were charged twice this month.")}
#=> {{:error, :timeout}, {:ok, "atlas"}}
```

`put_program/1` is also how a newly optimized router goes live: calls already
running finish with the program they started with, and later calls get the
new one.

## Credentials at runtime

In the application, the program comes from the file we saved, and the model
from runtime configuration. Nothing secret is compiled into the release:

~~~elixir
def start(_type, _args) do
  lm = Imp.req_llm(System.fetch_env!("ROUTER_MODEL"), api_key: System.fetch_env!("ROUTER_API_KEY"))

  program =
    :ticket_router
    |> Application.app_dir("priv/ticket_router.json")
    |> Imp.read!()
    |> Imp.with_lm(lm)

  children = [
    {Task.Supervisor, name: TicketRouter.Tasks, max_children: 8},
    {TicketRouter.Server, program: program, tasks: TicketRouter.Tasks}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: TicketRouter.Supervisor)
end
~~~

Changing models is then a configuration change, and rotating a key is a
restart.

The
[deployment example](https://github.com/deepfates/imp/blob/v0.5.0/examples/deployment/README.md)
is the complete version of this page: a two-stage program like `TicketTriage`,
learned parameters loaded and reloaded as an `Imp.Optimizer.Artifact`, crashed
and timed-out calls contained, and the whole thing restarted in a fresh OS
process. It runs without a provider.
[Running Imp in production](../production.md) and
[Runs and supervision](../diving-deeper/runs-and-supervision.md) go further.

---

**Next:** [Where to go next →](where-to-go-next.md)

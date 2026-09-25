# Composing programs

`Imp.react/3` is itself a composition: a predictor that chooses the next step,
a loop around it, and a few tools. We can build our own the same way. A
program is any struct whose module implements the `Imp.Module` behaviour, and
its stages are ordinary Imp programs held in its fields.

Let's split routing into two stages: first say plainly what is going wrong,
then route on the ticket and that summary.

```elixir
defmodule TicketTriage do
  @behaviour Imp.Module

  defstruct [:analyze, :route]

  def new(lm) do
    %__MODULE__{
      analyze:
        "ticket -> problem: string"
        |> Imp.signature("Say in one sentence what is going wrong, in plain words.")
        |> Imp.predict(lm: lm),
      route:
        "ticket, problem -> team: enum[atlas,harbor,beacon,quill]"
        |> Imp.signature("Route the support ticket to the squad that owns it.")
        |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)
    }
  end

  @impl true
  def call(%__MODULE__{} = triage, %{ticket: ticket}) do
    with {:ok, analysis} <- Imp.call(triage.analyze, %{ticket: ticket}),
         problem = Imp.get(analysis, :problem),
         {:ok, routing} <- Imp.call(triage.route, %{ticket: ticket, problem: problem}) do
      {:ok, Imp.prediction(problem: problem, team: Imp.get(routing, :team))}
    end
  end

  @impl true
  def optimizer_predictors(triage), do: [analyze: triage.analyze, route: triage.route]

  @impl true
  def update_optimizer_predictor(triage, :analyze, fun), do: %{triage | analyze: fun.(triage.analyze)}
  def update_optimizer_predictor(triage, :route, fun), do: %{triage | route: fun.(triage.route)}
end
```

`new/1` builds the stages. `call/2` runs them: plain Elixir, with `with` to
stop at the first error. A stage that fails returns its error, and the caller
gets it unchanged.

```elixir
triage = TicketTriage.new(lm)

{:ok, prediction} =
  Imp.call(triage, %{ticket: "Receipt emails have not been sent for any order since the deploy."})

{Imp.get(prediction, :problem), Imp.get(prediction, :team)}
#=> {"Since the deploy, receipt emails are not being sent for any orders.", "beacon"}
```

The summary is accurate and the route is wrong: by our charters, email that
isn't being delivered is a platform failure, harbor's.

The last two functions are optional. They name the predictors inside the
program, so optimizers can improve each stage the way they improve a single
predictor. Without them, `TicketTriage` still runs, evaluates, and serves; it
just can't be tuned.

## Why split a program

This split won't make our router more accurate by itself; the model still
doesn't know our squads. Splitting pays when a task outgrows one request:

- **Different models for different stages.** Each stage has its own `lm:`, so
  a cheap model can summarize and a stronger one can decide.
- **Checks between stages.** `call/2` is ordinary code, so it can validate,
  branch, retry, or call the next stage several times at once with `Task`.
- **Stages we can measure.** Each stage is a program, so we can call, test,
  and score one on its own.
- **Reuse.** A good summarizer isn't specific to routing.

In tests, `TicketTriage.new(scripted)` gives both stages a scripted model.
[Modules and composition](../diving-deeper/modules-and-composition.md) has
more patterns: branching, retries, and parallel stages.

---

**Next:** [Measuring →](measuring.md)

# Modules and composition

## Intent

A module is anything you can call as a program: a struct whose module
implements `Imp.Module`. `Imp.predict/2` is the smallest one. The others either
wrap a predictor with a strategy (reason first, sample several times, loop over
tools) or are yours: a struct that holds a few programs and calls them in
order.

Read this when one predictor is not enough and you want several steps, when
you want an optimizer to improve each step of your own program, or when you
are choosing between the built-in variants.

## Design decisions

### 1. A program is a struct with `call/2`

The whole contract is one callback: `call(program, inputs)` returns
`{:ok, %Imp.Prediction{}}` or `{:error, reason}`. There is no base class, no
`forward` to override, no registration. Call any program through
`Imp.call/2`. It turns a crash, a throw or a malformed return inside the
program into `{:error, reason}`, so an evaluation over a hundred examples
reports one bad row instead of stopping.

### 2. Composition is ordinary Elixir

A multi-step program is a struct whose fields are programs, and a `call/2`
that runs them, usually in a `with`. Control flow is Elixir: branch on a
field, loop, call a function, skip a step. A failing step returns its error
and the `with` stops there. Nothing is hidden in a framework method, so what
runs is what you read.

### 3. You name the predictors an optimizer may change

Optimizers improve predictors: their instructions, their demos, their request
config. Imp does not search your struct for them. A module that wants its
steps optimized says which predictors it has, under which names, and how to
put an updated one back, with two callbacks:
`optimizer_predictors/1` and `update_optimizer_predictor/3`. The names become
the parameter IDs you see in a saved program (`predictor/route/instruction`).
Anything you leave out stays exactly as you wrote it, and a predictor held
somewhere unexpected (inside a closure, in a process) is never silently
missed or silently included.

The built-in modules already do this: each exposes the predictor it wraps as
`:main`.

### 4. Strategies wrap programs

Chain of thought adds a `reasoning` output to a predictor. Best-of-n and
refine take any program and call it several times. Parallel takes any program
and runs it over many inputs. None of them is a second implementation of
prediction, so an improvement to a predictor, or an optimizer that works on
one, reaches every strategy built on it.

### 5. The model is part of the program

Pass `lm:` when you build a program. Each predictor then carries its own
model, and a pipeline can use a cheap model for routing and a stronger one
for the reply. `Imp.with_lm/2` returns a copy on another model;
`Imp.context/2` overrides the model for everything called inside a function,
which is how a test swaps in `Imp.LM.Static` without touching the program.

## API walkthrough

### Writing a module

Route the ticket, then draft a reply that names the squad:

```elixir
defmodule Support do
  @behaviour Imp.Module
  defstruct [:route, :reply]

  def new(opts) do
    %__MODULE__{
      route: Imp.predict("ticket -> team: enum[atlas,harbor,beacon,quill]", opts),
      reply: Imp.predict(~s(ticket, team -> reply: string "One sentence to the customer, naming the team."), opts)
    }
  end

  @impl true
  def call(%__MODULE__{} = support, inputs) do
    with {:ok, routed} <- Imp.call(support.route, inputs),
         team = Imp.get(routed, :team),
         {:ok, replied} <- Imp.call(support.reply, Map.put(inputs, :team, team)) do
      {:ok, Imp.prediction(team: team, reply: Imp.get(replied, :reply))}
    end
  end

  @impl true
  def optimizer_predictors(support), do: [route: support.route, reply: support.reply]

  @impl true
  def update_optimizer_predictor(support, :route, fun), do: %{support | route: fun.(support.route)}
  def update_optimizer_predictor(support, :reply, fun), do: %{support | reply: fun.(support.reply)}
end
```

Run it with a scripted model:

```elixir
lm =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)

      if prompt =~ "One sentence to the customer",
        do: %{reply: "The atlas squad will refund the duplicate charge."},
        else: %{team: "atlas"}
    end
  )

support = Support.new(lm: lm)
{:ok, prediction} = Imp.call(support, %{ticket: "We were charged twice this month."})

{Imp.get(prediction, :team), Imp.get(prediction, :reply)}
#=> {"atlas", "The atlas squad will refund the duplicate charge."}
```

Both steps are visible to optimizers, under the names you gave them:

```elixir
Imp.ProgramParameters.snapshot(support).parameters |> Enum.map(& &1.id)
#=> ["predictor/reply/config", "predictor/reply/demos", "predictor/reply/instruction", "predictor/route/config", "predictor/route/demos", "predictor/route/instruction"]
```

So `Imp.optimize!/3` works on `Support` as it does on a single predictor. A
labeled example that carries `ticket`, `team` and `reply` becomes a demo for
each step:

```elixir
trainset = [
  Imp.example(ticket: "Please refund the unused seats.", team: "atlas", reply: "atlas will refund the unused seats.")
  |> Imp.with_inputs(:ticket)
]

improved = Imp.optimize!(support, Imp.Optimizer.LabeledFewShot.new(k: 1), trainset)

{length(improved.route.demos), length(improved.reply.demos)}
#=> {1, 1}
```

`Imp.Module` also has an optional `execute/3`, for programs that run tools
under a run's authorization (see [Tools and MCP](tools-and-mcp.md)), and a
pair of callbacks for optimizing data other than predictors.

A custom module is your code, so it is not saved as a whole. What an
optimizer chose for it is data: `Imp.ProgramParameters.values/1` reads it,
`Imp.ProgramParameters.apply_values/2` puts it on a freshly built program, and
`Imp.Optimizer.Artifact` writes it to a checksummed file. The
[deployment example](https://github.com/deepfates/imp/blob/main/examples/deployment/README.md)
does this in a supervised application.

### Built-in variants

Grouped by what they are for. `Imp.predict/2` and `Imp.chain_of_thought/2`
are stable; every other module on this page is experimental, and its options
may change in a minor release.

#### Reason before answering

`Imp.chain_of_thought(signature, opts)` puts a `reasoning` output ahead of
yours, so the model writes its reasoning before the answer. The prediction
carries it as `Imp.get(prediction, :reasoning)`. It takes the same options as
`Imp.predict/2`.

#### Sample several times and keep the best

These are experimental.

`Imp.best_of_n(program, metric, n: 3)` calls the program up to `n` times and
keeps the prediction the metric scores highest, stopping early when one
reaches `threshold:` (1.0 by default). Each attempt runs at temperature 1.0
with its own rollout ID, so the attempts differ and none is served from the
cache. The metric is `fn example, prediction -> score end`; the example holds
the call's inputs, since there is no gold answer at inference time.

```elixir
drafts = %{
  0 => "We are so sorry about this; the billing squad will look into the duplicate charge today.",
  1 => "Billing will refund the duplicate charge.",
  2 => "Sorry!"
}

drafter =
  Imp.predict("ticket -> reply",
    lm: Imp.LM.Static.new(handler: fn _messages, opts -> %{reply: drafts[opts[:rollout_id]]} end)
  )

short_and_specific = fn _example, prediction ->
  reply = Imp.get(prediction, :reply)
  if reply =~ "refund" and String.length(reply) < 60, do: 1.0, else: 0.0
end

best = Imp.best_of_n(drafter, short_and_specific, n: 3)
{:ok, prediction} = Imp.call(best, %{ticket: "We were charged twice this month."})

Imp.get(prediction, :reply)
#=> "Billing will refund the duplicate charge."
```

`Imp.refine(program, metric, n: 3)` has the same shape, and between attempts
it asks the model for advice on what to fix. The advice reaches the next
attempt as a `hint_` input. Pass `feedback_fn:` to write the advice yourself.

`Imp.majority(values, field: :team)` is a function, not a module: it counts
values (or a field of predictions), after trimming and lowercasing, and
returns the most common. Ties go to the first. Nothing calls a model.

```elixir
Imp.majority(["atlas", "Atlas", "harbor"])
#=> "atlas"
```

`Imp.multi_chain_comparison(signature, m: 3)` takes `m` finished attempts as
a `completions` input and asks the model for one answer that weighs them.
Generate the attempts however you like.

#### Run many at once

Experimental. `Imp.parallel(program, inputs_list)` runs one program over many
inputs in supervised tasks, and `Imp.parallel([{program, inputs}, ...])` runs
different programs together. Results come back in input order, one
`{:ok, prediction}` or `{:error, reason}` per input, so one failure stays in
its own slot. `num_threads:` bounds how many run at once and `timeout:`
bounds each call.

```elixir
router =
  Imp.predict("ticket -> team",
    lm:
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if List.last(messages).content =~ "charged", do: %{team: "atlas"}, else: %{team: "beacon"}
        end
      )
  )

router
|> Imp.parallel([%{ticket: "We were charged twice."}, %{ticket: "I can't log in."}])
|> Enum.map(fn {:ok, prediction} -> Imp.get(prediction, :team) end)
#=> ["atlas", "beacon"]
```

`Imp.evaluate/4` already runs examples in parallel; reach for
`Imp.parallel/2` for your own batches.

#### Compute with code

These are experimental. The model writes a small program in a restricted
subset of Elixir, and Imp runs it in its own interpreter: generated code is
parsed and checked against an allowlist, never passed to `Code.eval_string/3`.
The interpreter bounds steps, value sizes and effects. It is not an operating
system sandbox; it runs inside your VM, so keep the tools you give it narrow.

- `Imp.program_of_thought(signature, opts)` asks for a program that computes
  the answer, runs it, and on an error asks again with the error. The outputs
  come from the program's value.
- `Imp.code_act(signature, tools, opts)` alternates between running code and
  calling tools until it can answer.
- `Imp.rlm(signature, opts)` puts large inputs into the interpreter as
  variables instead of into the prompt, and lets the model explore them with
  code, call a sub-model on pieces (`llm_query/1`, `llm_query_batched/1`), and
  finish with `submit/1`, which is checked against your signature. Use it when
  an input is too large or too structured for one prompt. Iterations,
  sub-model calls, recursion depth and wall time each have their own budget;
  see `Imp.Predict.RLM`, and
  [Livebook 04](../../livebooks/04_tools_agents_mcp_rlm.livemd) for RLM runs
  with lazy inputs, batched sub-queries and a budget that stops a loop.

#### Use tools

`Imp.react(signature, tools, opts)` is the tool loop. It has its own page:
[ReAct](react.md).

## Cross-links

- [Signatures](signatures.md): what a predictor declares.
- [ReAct](react.md): the tool loop.
- [Tools and MCP](tools-and-mcp.md): tools, and running a program under a
  host's authorization.
- `Imp.Module`, `Imp.ProgramParameters`: the reference.

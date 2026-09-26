# Imp

Program language models in Elixir, measure what they do, and improve them from
examples.

Imp brings [DSPy](https://dspy.ai)'s idea to the BEAM: instead of writing
prompt strings and parsing whatever comes back, you declare what a step takes
and returns, run it as an ordinary Elixir value, score it on examples, and let
an optimizer make it better. The model is used where judgment is needed;
everything around it stays plain, testable code.

<!-- "Imp with cards", Le Grand Etteilla (public domain, via Wikimedia Commons) -->
<p align="center">
  <img src="assets/imp-with-cards.jpg" width="340"
       alt="An imp studies a hand of cards through a lens while a smaller imp springs from its tail.">
</p>

## A program, not a prompt

Say your support tickets go to four squads with internal names: **atlas** owns
money, **harbor** the platform, **beacon** identity, **quill** the product.

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} = Imp.call(router, %{ticket: "We were charged twice this month."})
Imp.get(prediction, :team)
#=> "harbor"
```

Imp writes the prompt from the signature and checks the answer against it, so
the team is always one of the four, never free text. It is also wrong: a
double charge is money, which is atlas. The model is guessing, because nothing
tells it what your squad names mean.

## Measure it, then improve it

Imp ships sixty labeled tickets for this router, split into training and test
sets. Score the router on the test set, give it examples, and score it again:

```elixir
data = :imp |> Application.app_dir("priv/tutorial/support_tickets.json") |> File.read!() |> Jason.decode!()

examples = fn rows ->
  for %{"ticket" => t, "team" => team} <- rows,
      do: Imp.example(ticket: t, team: team) |> Imp.with_inputs(:ticket)
end

metric = Imp.exact_match(:team)

Imp.evaluate(router, examples.(data["test"]), metric).score
#=> 0.25

improved =
  Imp.optimize!(router, Imp.Optimizer.LabeledFewShot.new(k: 8), examples.(data["train"]))

Imp.evaluate(improved, examples.(data["test"]), metric).score
#=> 0.75
```

The optimizer added eight solved tickets from the training set to the program.
In six runs with `gpt-5.4-mini` the router went from 20–45% to 75–85% on
tickets it never saw, for about a cent each. The improvement is data you can
read (`improved.demos`), save with the program, and review like any other
change. Stronger optimizers search over instructions and examples when a task
needs more.

## It runs in your application

An Imp program is a value. Test it with a scripted model instead of a
provider, save the improved version without credentials, and serve it from a
supervised process with bounded concurrency and timeouts. The same pieces grow
into tools and agents, retrieval, multi-step programs, and a dozen optimizers,
when a task needs them.

The core is stable: the `Imp` facade, signatures, adapters, `Imp.predict`,
`Imp.chain_of_thought` and `Imp.react`, evaluation, tools, telemetry and
saving. The reference groups the other optimizers, agent loops, training
integrations and runs under **Experimental optimizers and advanced
workflows**; those may change before 1.0.

## Install

```elixir
{:imp, "~> 0.5"}
```

Imp needs Elixir 1.19 and a C++ compiler for one dependency (erlexec).

## Next

- **[Getting started](docs/getting-started/index.md)** builds this router step
  by step, from the first call to running it in an application.
- **[Coming from DSPy](docs/coming-from-dspy.md)** maps what you already know.
- **[Cheatsheet](docs/cheatsheet.cheatmd)** has the common calls on one page.

Imp is MIT licensed.

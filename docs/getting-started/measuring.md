# Measuring

So far we've judged the router one ticket at a time, which tells us very
little. Before changing it, let's give it a number.

## Examples

Imp ships sixty labeled tickets for this router, split into training,
development, and test sets of twenty:

```elixir
data =
  :imp
  |> Application.app_dir("priv/tutorial/support_tickets.json")
  |> File.read!()
  |> Jason.decode!()

examples = fn rows ->
  for %{"ticket" => ticket, "team" => team} <- rows do
    Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
  end
end

trainset = examples.(data["train"])
devset = examples.(data["dev"])
testset = examples.(data["test"])

Imp.to_map(hd(testset))
#=> %{ticket: "Downgrade our plan to the starter tier at the end of the term.", team: "atlas"}
```

An example is a row of named fields. `Imp.with_inputs/2` says which of them
the program receives; the rest are labels, held back for scoring.

The three sets have different jobs. Optimizers learn from the training set and
may use the development set to choose between candidates. The test set is for
the end: the score that counts comes from tickets nothing was tuned on.

## A metric

A metric scores one prediction against one example. For routing, the right
metric is plain: the ticket reached the right squad or it didn't.

```elixir
metric = Imp.exact_match(:team)
```

A metric can also be any function of `(example, prediction)` that returns a
boolean or a number, such as partial credit, a rule-based check, or a call to
another model acting as a judge.

`Imp.evaluate/4` runs a program on every example and applies the metric. Before
spending anything, we can check the harness with a scripted model. A router
that always says atlas should score exactly the share of tickets that belong
to atlas:

```elixir
always_atlas = Imp.with_lm(router, Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end))

Imp.evaluate(always_atlas, testset, metric).score
#=> 0.25
```

Five of the twenty test tickets are atlas's, so the harness counts correctly.

## A baseline

Now the router from the first page, on the twenty test tickets:

```elixir
baseline = Imp.evaluate(router, testset, metric, num_threads: 8)
baseline.score
#=> 0.25
```

Five right out of twenty. `num_threads: 8` scores eight tickets at a time,
each in its own supervised process.

`baseline.rows` has one row per example, with the prediction and its score.
The misses show what the model is doing:

```elixir
for row <- baseline.rows, not row.passed? do
  {Imp.get(row.example, :ticket), Imp.get(row.prediction, :team), Imp.get(row.example, :team)}
end
```

```text
{"Downgrade our plan to the starter tier at the end of the term.", "harbor", "atlas"}
{"The proration on our upgrade looks wrong by about $40.", "harbor", "atlas"}
{"Our purchase order number is missing from the invoice.", "harbor", "atlas"}
{"Do you offer nonprofit discounts on the team plan?", "harbor", "atlas"}
{"The currency on our invoice should be EUR, not USD.", "harbor", "atlas"}
{"Scheduled reports did not run last night.", "beacon", "harbor"}
{"We're seeing elevated latency from the eu-west region.", "atlas", "harbor"}
{"The search index seems stale; new records don't appear.", "beacon", "harbor"}
{"The mobile app can't sync; requests fail with DNS errors.", "beacon", "harbor"}
{"We want to restrict API tokens to read-only scopes.", "harbor", "beacon"}
{"Please enable IP allowlisting for our admin accounts.", "atlas", "beacon"}
{"Can the weekly digest email be customized with our logo?", "harbor", "quill"}
{"Is there an on-prem version of the product?", "atlas", "quill"}
{"The mobile app is missing the reports tab.", "beacon", "quill"}
{"Can I merge two workspaces into one?", "harbor", "quill"}
```

Every money ticket went to harbor. The model reads the tickets fine; it
doesn't know what our squad names mean, so it guesses, and mostly guesses
wrong.

The other programs from this guide take the same signature's inputs, so we
can measure them the same way:

```elixir
for {name, program} <- [router: router, thinking_router: thinking_router, triage: triage, agent: agent] do
  {name, Imp.evaluate(program, testset, metric, num_threads: 8).score}
end
#=> [router: 0.25, thinking_router: 0.3, triage: 0.25, agent: 0.75]
```

Chain of thought and the two-stage triage barely move: reasoning can't supply
a fact the model was never given. The agent does much better, because its tool
tells the model what the squads own. That works when someone has written the
rules down. Often no one has, and what we have instead are examples of past
decisions. The next page turns those into a better program.

Twenty examples score in steps of 0.05, and a model's answers vary between
runs, so read these as levels, not exact values. Across three runs with
`gpt-5.4-mini`, the router scored 0.25 to 0.3, chain of thought 0.3 to 0.35,
triage 0.25 to 0.4, and the agent 0.75 to 0.95. The evaluations on this page
cost about five cents.

[Metrics and evaluation](../diving-deeper/metrics-and-evaluation.md) covers
richer metrics and what else an evaluation reports.

---

**Next:** [Improving →](improving.md)

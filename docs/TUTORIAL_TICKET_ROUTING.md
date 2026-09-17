# Ticket Routing: Measure It, Then Make It Better

Let's take the support-ticket router from the [README](../README.md) and do
what you cannot do with a prompt string: score it on held-out data, improve it
with an optimizer, and prove the improvement on tickets it has never seen.

The zero-shot router scored **30–50%** on twenty held-out tickets; the
optimized router scored **95–100%** on the same twenty in all three repeats.
Each full experiment — baseline, optimization, and held-out evaluation — cost
about **$0.013** and ran in **8–9 seconds** with `gpt-5.4-mini`.

Those are rows R1 and R2 in
[benchmarks/RESULTS.md](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md),
which carries the dataset, model, provider, date and commit. You can measure
them yourself: with an API key,
`mix run scripts/tutorial_ticket_routing_experiment.exs` in a source checkout
runs exactly this experiment three times, for about four cents in total. The
packaged tutorial below uses the same public program, evaluation and optimizer
APIs without that runner.
The gain has a plain-English reason: our routing labels encode conventions
the model cannot guess, and the optimizer put examples of those conventions
into the program.

## The Task

Your company routes tickets to four squads with internal names:

- **atlas** owns money: charges, refunds, invoices, plans.
- **harbor** owns the platform: outages, errors, latency — including technical
  failures in payment and email delivery.
- **beacon** owns identity: accounts, credentials, sessions, data exposure.
- **quill** owns product experience: feature requests, how-to questions, docs.

No model knows any of this. "Refund attempts fail with a gateway timeout
error" *sounds* like a money problem, but by your conventions a gateway
timeout belongs to harbor. That gap between what a model can read and what
your organization means is exactly what examples-plus-a-metric fixes.

Imp ships the sixty labeled tickets used here, already split twenty/twenty/
twenty into train, dev, and test. Load them:

```elixir
data =
  :imp
  |> Application.app_dir("priv/tutorial/support_tickets.json")
  |> File.read!()
  |> Jason.decode!()

to_examples = fn rows ->
  for %{"ticket" => ticket, "team" => team} <- rows do
    Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
  end
end

trainset = to_examples.(data["train"])
testset = to_examples.(data["test"])
```

The train set is the only data the optimizer may look at. The test set exists
to answer one question at the end: did this get better on tickets nobody
selected for?

## Declare The Router

Same shape as the README, trimmed to the routing decision:

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])
```

The enum means the model's answer is always one of your four squads. When the
model returns anything else, Imp rejects it against the declared type and
retries with the validation error — you never parse free text.

## Measure Before Changing It

A metric turns "seems fine" into a number. Exact match on the `team` field is
the honest metric for routing: the ticket either reached the right squad or it
did not.

Twenty live calls cost well under a cent; this takes a few seconds:

```elixir
metric = Imp.exact_match(:team)

baseline = Imp.evaluate(router, testset, metric, max_concurrency: 8, timeout: 60_000)
baseline.score
#=> 0.3
```

The zero-shot router got 6 of 20 right. `baseline.rows` shows every miss, and
the misses are not random — they are the model guessing what squad names mean:

```text
"The proration on our upgrade looks wrong by about $40."  -> got "harbor", want "atlas"
"Scheduled reports did not run last night."               -> got "beacon", want "harbor"
"Please enable IP allowlisting for our admin accounts."   -> got "atlas",  want "beacon"
"Is there an on-prem version of the product?"             -> got "harbor", want "quill"
```

It reads the tickets fine. It cannot know that atlas is the money squad. On a
task this small the exact score moves a little between runs — our current
repeats landed between 0.30 and 0.50 — but every run tells the same story.

## Improve With Measured Lift

An optimizer compiles your program into a better one using training data and
the metric. The simplest optimizer, `LabeledFewShot`, attaches labeled
training examples to the program as demonstrations — the model sees eight
solved tickets before it sees yours:

```elixir
optimizer = Imp.Optimizer.LabeledFewShot.new(k: 8, sample: false)

compiled = Imp.optimize!(router, optimizer, trainset)
```

This one runs in milliseconds and makes no model calls. The explicit ordered
mode selects the first eight training examples (two per squad in the shipped
set); the optimizer's general default is deterministic sampling. Search optimizers
spend real model calls comparing many candidate programs — budget dollars and
minutes for those the way you would for any experiment. `RandomSearch` takes
the same `Imp.optimize!/3` shape; `MIPROv2` also requires a validation set, so
it uses `Imp.optimize!/4` with your dev split as the fourth argument.

## Prove It On Held-Out Data

The only score that counts comes from tickets the optimizer never saw:

```elixir
optimized = Imp.evaluate(compiled, testset, metric, max_concurrency: 8, timeout: 60_000)

{baseline.score, optimized.score}
#=> {0.3, 0.95}
```

The three repeats measured 50% → 95%, 35% → 100%, and 30% → 95%: gains of
45–65 points on held-out tickets. Each run used about 14,800 tokens, cost about
$0.013, and finished in 8–9 seconds; all 120 evaluation calls completed without
a row error and the cache was cleared before each repeat, so every call was
live. Twenty rows move in 5-point steps, so trust the direction and the
magnitude, not the endpoints. Rows R1 and R2 in
[benchmarks/RESULTS.md](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md).

It is not a magic button. The remaining misses are genuinely marginal tickets
("Scheduled reports did not run last night" — a platform failure that reads
like a product question), and with a train set this small the improved program
can overfit to quirks of those twenty examples. When the gain matters, keep a
third split the optimizer never touches and check the winner once, at the end.

## Inspect What Actually Changed

The improvement is not magic either — it is data you can read. The compiled
program carries its demonstrations:

```elixir
for demo <- compiled.demos do
  {Imp.get(demo, :ticket), Imp.get(demo, :team)}
end
```

```text
{"We were charged twice for the March invoice.", "atlas"}
{"Card payments have been timing out at checkout since 9am.", "harbor"}
{"I can't log in after resetting my password.", "beacon"}
{"Can you add a dark mode to the dashboard?", "quill"}
{"Please send a copy of last month's receipt for our records.", "atlas"}
{"The API is returning 502 errors intermittently.", "harbor"}
{"A former employee still has access to our workspace.", "beacon"}
{"How do I export my data to CSV?", "quill"}
```

Before optimization, the model saw your ticket cold. After, it sees the eight
solved tickets rendered as prior conversation turns, then yours (abridged —
Imp renders each turn with explicit field markers):

```text
user:      Card payments have been timing out at checkout since 9am.
assistant: harbor
user:      I can't log in after resetting my password.
assistant: beacon
...
user:      Refund attempts fail with a gateway timeout error.
```

That last ticket is the trap from the baseline — the zero-shot router sent it
to atlas (money). The compiled router answers **harbor**, because the second
demo taught it that payment timeouts are platform failures. The demos are
program data, not hidden prompt strings: they survive `Imp.save!/2`, travel
with the artifact, and can be reviewed like any other data.

## Ship It

The compiled router is a value. Persist it without secrets and load it in
your application:

```elixir
:ok = Imp.save!(compiled, "ticket_router.json")

router = Imp.load!("ticket_router.json")
```

Credentials never enter the artifact; bind the live model at runtime with
`Imp.with_lm/2` or a scoped `Imp.context/2`.

The experiment script also writes the optimized parameters as an
`Imp.Optimizer.Artifact`, starts a fresh OS process, reconstructs the trusted
router, applies only those parameters, and serves four concurrent OTP tasks.
All four fresh-process probes routed correctly; the artifact never contained
the provider credential or executable application code.

## Where To Go Next

- Swap in your own tickets and teams: the whole experiment is the JSON file
  plus the code above.
- When labeled demos stop helping, try the search optimizers in the
  [Learning Path](LEARNING_PATH.md#3-improve-with-measured-lift) — same program,
  same metric, bigger budget.
- [Livebook 03](../livebooks/03_evaluate_and_optimize.livemd) runs this
  workflow interactively.
- [Benchmarks](https://github.com/deepfates/imp/blob/main/docs/BENCHMARKS.md) lists every number this repository publishes,
  what each costs to re-measure, and what cannot be re-measured at all.

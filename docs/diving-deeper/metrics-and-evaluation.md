# Metrics and evaluation

## Intent

A metric is the function that turns one prediction into a score, and
`Imp.evaluate/4` runs a program over a set of examples and scores every
answer. Optimizers are built on the same two pieces: they are evaluation in a
loop. This page covers the metric contract, the report `Imp.evaluate/4`
returns, the built-in metrics, judges that are themselves language-model
programs, and how to keep training, validation and test data apart.

Read it when you write your own metric, swap a rule for a judge, or wonder
why a score came out the way it did.

## Design decisions

### 1. A metric is a function of the example and the prediction

```elixir
metric = fn example, prediction ->
  Imp.get(prediction, :team) == Imp.get(example, :team)
end
```

No behaviour to implement and no registration. Anything that scores text in
Elixir can be a metric in one line. `Imp.evaluate/4` and every optimizer
check the function's arity when you build them, so a metric with the wrong
shape fails at once, not halfway through a run.

### 2. The trace tells a metric whether it is being evaluated

`fn example, prediction, trace -> ... end` receives `nil` as the trace when
the program is evaluated, by `Imp.evaluate/4` and by the validation scoring
optimizers do through it, and the program's trace (the rendered messages and
the raw model output) when an optimizer bootstraps demos from a run. This is
DSPy's `trace=None` switch: a metric can be stricter about the examples it
lets become demos than about the score it reports.

### 3. Return a boolean, a number, or a map with a score and feedback

`true` scores 1.0 and `false` 0.0. A number is its own score and passes when
it is above zero. A map with `:score` and `:feedback` carries an explanation
with the score. Imp normalizes all of these into `Imp.Metrics.Result` before
averaging, so simple metrics stay simple and richer ones are not locked out.
A return value Imp cannot read scores 0.0, with the value kept in the row's
feedback so you can see what happened.

### 4. Feedback is for GEPA and for you

The report's score ignores feedback. Each row keeps it (`row.feedback`), and
GEPA reads it when it rewrites instructions. A metric that says *why* an
answer is wrong costs a sentence to write and gives the strongest optimizer
something to work with.

### 5. The score is a mean, not a percentage

`report.score` is the mean of the row scores, so a boolean metric gives the
fraction of examples that passed: `0.75`, not `75.0` as DSPy prints it.

### 6. A failure is a row, not an exception

When the program returns an error for an example, that row gets
`failure_score` (0.0 by default) and the error, and evaluation goes on. When
the metric itself raises, the row scores 0.0 with the exception in its
feedback. One bad example does not throw away the other nine hundred. When
you want a limit, `max_errors:` stops the run by raising
`Imp.EvaluationCancelledError` with the rows so far: a truncated run is never
returned as if it were complete.

### 7. Evaluation runs under supervision

Rows run one at a time by default. `num_threads:` runs them concurrently in
Imp's supervised task pool, which the `async_max_workers` setting bounds for
the whole node. `timeout:` limits each row; a row that runs out of time is
killed and recorded as `{:evaluation_task_exit, :timeout}`, so a killed call
is never mistaken for a wrong answer. Settings from `Imp.context/2`, such as a
different model, reach every row.

### 8. A judge is a program

When a rule cannot say whether an answer is good, ask a model. In Imp a
judge is an ordinary program with its own signature, called inside the
metric. It is traced, cached and counted like any other call, and you can
optimize it like any other program.

### 9. Train, validation and test are three different sets

An optimizer that selects on the examples it trained on overstates what it
found, and a test set that influenced any choice is no longer a test.
`Imp.Experiment.check/5` enforces the split: it refuses overlapping rows,
chooses between the original and the optimized program on validation data,
and scores only the chosen program on test data.

## API walkthrough

### Metric anatomy

The examples below use a scripted model that stands in for a real one: it
routes every ticket that mentions "charged" to atlas and everything else to
harbor.

```elixir
lm =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      if List.last(messages).content =~ "charged",
        do: %{team: "atlas"},
        else: %{team: "harbor"}
    end
  )

router = Imp.predict("ticket -> team: enum[atlas,harbor,beacon,quill]", lm: lm)

devset =
  for {ticket, team} <- [
        {"We were charged twice this month.", "atlas"},
        {"The dashboard logs me out every minute.", "beacon"},
        {"Webhooks stopped arriving at 3am.", "harbor"},
        {"Why was my card charged again?", "atlas"}
      ],
      do: Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
```

A metric that explains its misses:

```elixir
metric = fn example, prediction ->
  expected = Imp.get(example, :team)
  routed = Imp.get(prediction, :team)

  if routed == expected,
    do: true,
    else: %{
      score: 0.0,
      feedback: "Routed to #{routed}; #{expected} owns this kind of ticket."
    }
end
```

### `Imp.evaluate/4` and its report

```elixir
report = Imp.evaluate(router, devset, metric)

report.score
#=> 0.75

for row <- report.rows, row.score == 0.0, do: row.feedback
#=> ["Routed to harbor; beacon owns this kind of ticket."]
```

The report is an `Imp.Evaluate.Result`. Each row holds `:index`,
`:example`, `:prediction`, `:score`, `:passed?`, `:feedback`,
`:metric_metadata` and `:error`; `report.errors` lists the rows that failed.
Write the rows out with `Imp.Evaluate.Result.save_as_json/2` or
`save_as_csv/2`.

Options: `num_threads:` for concurrency, `timeout:` per row, `max_errors:`
to stop early, `failure_score:` for failed rows, and `display_progress:`.

### Failures

A program that cannot run on an example fails that row, not the evaluation:

```elixir
needs_customer = Imp.predict("ticket, customer -> team", lm: lm)
report = Imp.evaluate(needs_customer, devset, Imp.exact_match(:team))

{report.score, hd(report.rows).error, length(report.errors)}
#=> {0.0, {:missing_input_fields, ["customer"]}, 4}
```

### Built-in metrics

**`Imp.exact_match(field)`** compares one field after normalizing case,
punctuation, articles and whitespace. When the example holds a list, any
member matches:

```elixir
metric = Imp.exact_match(:answer)
metric.(Imp.example(answer: ["2", "two"]), Imp.prediction(answer: "Two."))
#=> true
```

The rest live in `Imp.Metrics`: `em/2`, `f1/2` and `hotpot_f1/2` for
token-level answers; `answer_passage_match/2` for retrieval programs;
`extractive_qa/3`, `classification/3` and `retrieval_recall/3`, which return
an `Imp.Metrics.Result` with details in its metadata; and
`classification_report/2`, which summarizes accuracy and F1 per label for a
list of `{gold, predicted}` pairs. All string metrics share
`Imp.Metrics.normalize_text/1`.

### Judges

A judge that checks a drafted reply against what the support team knows:

~~~elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

drafter =
  "ticket -> reply"
  |> Imp.signature("Write the first reply to this support ticket.")
  |> Imp.predict(lm: lm)

judge =
  "facts, ticket, reply -> acceptable: bool, critique"
  |> Imp.signature(
    "Would a support lead send this reply as written? Check it against the facts. " <>
      "Give the main problem in one sentence, or say it is fine."
  )
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

facts =
  "There is no dark mode and none is planned. Refunds take 5 to 7 business days. " <>
    "Support cannot see card numbers."

metric = fn example, prediction ->
  {:ok, verdict} =
    Imp.call(judge, %{
      facts: facts,
      ticket: Imp.get(example, :ticket),
      reply: Imp.get(prediction, :reply)
    })

  %{
    score: if(Imp.get(verdict, :acceptable), do: 1.0, else: 0.0),
    feedback: Imp.get(verdict, :critique)
  }
end

tickets =
  for ticket <- [
        "We were charged twice this month.",
        "Webhooks stopped arriving at 3am.",
        "Can I add dark mode?"
      ],
      do: Imp.example(ticket: ticket) |> Imp.with_inputs(:ticket)

report = Imp.evaluate(drafter, tickets, metric)
report.score
#=> 0.6666666666666666

Enum.map(report.rows, & &1.feedback) |> List.last()
#=> "The reply is inconsistent with the facts: there is no dark mode and none is planned,
#=>  so it should not suggest that it may be available or offer to help find a setting."
~~~

The drafter had answered "Yes — dark mode may be available depending on the
app or plan you're using." Replies and verdicts vary between runs. On
another run, with no facts, the judge passed a reply that promised dark mode:
a judge knows only what its inputs tell it.

Imp also ships DSPy's two judges as programs. `Imp.Evaluate.SemanticF1` asks a
model for the precision and recall of a response against a reference and
scores their F1; `Imp.Evaluate.CompleteAndGrounded` scores completeness
against the reference and grounding in retrieved context. Call either with
`%{example: example, pred: prediction}` inside a metric and return the
prediction it gives back; its `:score` field is the score.

### Train, validation and test

`Imp.Experiment.Data.new/1` identifies every row before any model is called
and refuses a row that appears in two splits. `Imp.Experiment.check/5`
evaluates the original and the optimized program on the selection split,
keeps the better one (the original on a tie), and only then scores it on
the test split. Here the scripted model routes billing tickets right only
when a billing demo is in its prompt:

```elixir
lm =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)

      if prompt =~ "cancelled" and List.last(messages).content =~ "charged",
        do: %{team: "atlas"},
        else: %{team: "harbor"}
    end
  )

router = Imp.predict("ticket -> team: enum[atlas,harbor,beacon,quill]", lm: lm)

rows = fn pairs ->
  for {ticket, team} <- pairs,
      do: Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
end

data =
  Imp.Experiment.Data.new(
    train:
      rows.([
        {"I was charged for a plan I cancelled.", "atlas"},
        {"The API returns 502s.", "harbor"}
      ]),
    selection:
      rows.([
        {"We were charged twice this month.", "atlas"},
        {"Webhooks stopped arriving.", "harbor"}
      ]),
    test:
      rows.([
        {"Why was my card charged again?", "atlas"},
        {"Deploys hang at 90%.", "harbor"}
      ])
  )

{:ok, result} =
  Imp.Experiment.check(
    router,
    Imp.Optimizer.LabeledFewShot.new(k: 2),
    data,
    Imp.exact_match(:team)
  )

{result.selected, result.baseline_selection.score, result.optimized_selection.score,
 result.test.score}
#=> {:optimized, 0.5, 1.0, 1.0}
```

`result.artifact` holds the chosen parameters, ready for
[Saving and artifacts](saving-and-artifacts.md), and `result.program` is the
chosen program. With a noisy model, `evaluation_options: [repetitions: 3]`
repeats each evaluation over the same rows.

## Cross-links

- [Choosing an optimizer](choosing-an-optimizer.md): which optimizers read
  feedback and which need a validation set.
- [Settings and context](settings-and-context.md): how `Imp.context/2`
  reaches every evaluated row.
- [Runs and supervision](runs-and-supervision.md): the task pool that bounds
  `num_threads:`.
- `Imp.Evaluate` and `Imp.Metrics` list every option and function.

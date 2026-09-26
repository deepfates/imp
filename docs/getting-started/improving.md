# Improving

We have a router, a metric, and a baseline. An **optimizer** takes a program,
training examples, and a metric, and returns a new program that does better on
them. We don't edit the prompt; we give the optimizer data and let it make the
changes.

## Showing the model solved tickets

The simplest optimizer, `LabeledFewShot`, attaches labeled training examples to
the program as demonstrations. The model sees solved tickets before it sees
ours:

```elixir
improved = Imp.optimize!(router, Imp.Optimizer.LabeledFewShot.new(k: 8), trainset)

Imp.evaluate(improved, testset, metric, num_threads: 8).score
#=> 0.75
```

The router went from 0.25 to 0.75 on tickets it never saw. In six more runs,
each in a fresh VM, it went from 0.2–0.45 to 0.75–0.85. Optimizing made no
model calls; the only cost is a longer prompt.

`improved` is a new value. `router` is unchanged, so we can compare the two, or
keep both.

## What changed

The improvement is data we can read. The optimizer sampled eight training
tickets, with a fixed seed, so it picks the same eight every time:

```elixir
for demo <- improved.demos, do: {Imp.get(demo, :ticket), Imp.get(demo, :team)}
```

```text
{"Our VAT number is wrong on the latest invoice.", "atlas"}
{"Card payments have been timing out at checkout since 9am.", "harbor"}
{"Two-factor codes are not being accepted.", "beacon"}
{"I cancelled in April but was still charged in May.", "atlas"}
{"How do I switch from monthly to annual billing?", "atlas"}
{"Does the API support filtering by created date?", "quill"}
{"Receipt emails have not been sent for any order since the deploy.", "harbor"}
{"Webhooks stopped being delivered around midnight UTC.", "harbor"}
```

and Imp renders them as earlier turns of the conversation, before our ticket.
The first pair:

```elixir
{:ok, prediction} = Imp.call(improved, %{ticket: "We were charged twice this month."})

[_system, user, assistant | _rest] = prediction.metadata.trace.messages
IO.puts(user.content <> "\n\n" <> assistant.content)
```

```text
[[ ## ticket ## ]]
Our VAT number is wrong on the latest invoice.

{
  "team": "atlas"
}
```

Seven more pairs follow, and then our ticket.

Nothing about the model changed, and no prompt was written by hand. The
examples show what our squad names mean, and the model generalizes from them.
Before we ship `improved`, we can read its demos like any other change to
our code, and they are saved with the program.

## Searching for better instructions

Demonstrations are one lever; the instruction is another. `Imp.Optimizer.GEPA`
runs the program on training tickets, shows a stronger model where it failed,
and has that model write a better instruction. It keeps the candidates that
score best on the development set. A metric can return feedback as well as a
score, to say *why* a prediction failed, and GEPA passes it along:

```elixir
strong_lm = Imp.req_llm("openai:gpt-5.4", api_key: System.fetch_env!("OPENAI_API_KEY"))

feedback_metric = fn example, prediction ->
  expected = Imp.get(example, :team)
  got = Imp.get(prediction, :team)

  if got == expected,
    do: %{score: 1.0, feedback: "Correct: #{expected}."},
    else: %{score: 0.0, feedback: "Wrong: this ticket belongs to #{expected}, not #{got}."}
end

optimizer =
  Imp.Optimizer.GEPA.new(feedback_metric, reflection_lm: strong_lm, max_metric_calls: 150, num_threads: 8)

searched = Imp.optimize!(router, optimizer, trainset, devset)

Imp.evaluate(searched, testset, metric, num_threads: 8).score
#=> 0.7
```

GEPA takes the development set as a fourth argument, so the test set stays
unseen. `max_metric_calls` is the budget: this run took about a minute and
cost about five cents. The instruction it wrote is part of the program:

```elixir
IO.puts(searched.signature.instructions)
```

```text
You are given a support ticket as plain text in a single input field:

- ticket: the customer’s issue/request

Your task is to route the ticket to exactly one owning squad and output only the squad name in the `team` field.

Possible squads seen so far:
- quill
- harbor
- beacon

Routing guidance inferred from prior examples:
- Route data export / CSV export / exporting customer data requests to `quill`.
- Route account access, workspace access, user offboarding, or former employee access/security issues to `beacon`.
- Route dashboard performance, slow page loads, uptime/reliability, or product performance issues to `harbor`.

Important requirements:
- Choose the single best owning squad based on the primary issue described in the ticket.
- Do not explain your reasoning.
- Do not output anything except the team name/value.
- Be careful not to confuse:
  - CSV/data export requests (`quill`)
  - access/security/account permission issues (`beacon`)
  - dashboard slowness/performance incidents (`harbor`)
```

It scored 0.7, below the demonstrations, and reading it shows a problem: it
lists three squads and never mentions atlas. An instruction that forgets a
squad is the kind of change we'd catch in review, and we can review it
because the optimizer's output is text.

With a budget this small, GEPA's result varies. Three runs scored 0.85, 0.7,
and 0.7, and cost five to eight cents each; the eight demonstrations scored
0.75 to 0.85 and cost nothing to compile. For this task, examples are the
better buy: what the model lacks is what our labels mean, and examples say
that directly. Instruction search is for tasks where the model needs to be
told *how* to work, and it wants a larger budget than a guide should spend.
[Choosing an optimizer](../diving-deeper/choosing-an-optimizer.md) compares
the rest.

[Livebook 03](../../livebooks/03_evaluate_and_optimize.livemd) runs these
optimizers in a notebook, offline or with a key.

---

**Next:** [Saving and loading →](save-and-load.md)

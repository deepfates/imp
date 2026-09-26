# Your first program

Let's write the simplest version of the router, run it, and then look at what
Imp did on our behalf.

```elixir
router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} = Imp.call(router, %{ticket: "We were charged twice this month."})
Imp.get(prediction, :team)
#=> "harbor"
```

The first line is a **signature**: what the task takes and what it returns,
written as `inputs -> outputs`. Our router takes a `ticket` and returns a
`team`, which must be one of four values. The second argument to
`Imp.signature/2` is the instruction, one sentence saying what the task is.

Names matter here in a way they don't in ordinary code, because the model
reads them. A field called `team` tells the model what we want; a field called
`x` would not.

`Imp.predict/2` turns the signature into a program. Signatures say *what* we
want; modules like `Imp.Predict` say *how* to get it. `Predict` is the simplest
module: one request to the model per call. We give it the model and an
adapter, which decides how the signature becomes messages. `Imp.Adapter.JSON`
asks for a JSON object; the default, `Imp.Adapter.Chat`, uses the same
`[[ ## field ## ]]` markers DSPy does. The examples use JSON because our
outputs are typed values our code reads, and a JSON object is a format
providers can be asked to return directly.

The router is a value. Nothing has run yet. `Imp.call/2` runs it:

1. Imp checks that the inputs the signature needs are present.
2. The adapter renders the signature, the instruction, and our ticket into
   messages.
3. The model replies.
4. The adapter parses the reply and checks every field against its type. Our
   `team` must be one of the four squads, or the call returns an error instead
   of a prediction.
5. We get `{:ok, %Imp.Prediction{}}`, and read fields with `Imp.get/2`.

Imp keeps a cache in memory for the life of the VM, so an identical call is
answered from it and running a block twice costs nothing the second time.

The router answered `"harbor"`. That is a valid squad and the wrong one: a
double charge is money, so it belongs to atlas. The model is guessing, because
nothing tells it what our squad names mean. Keep that in mind; fixing it is
what the second half of this guide is about.

## What the model saw

Every prediction carries the messages Imp sent and the raw reply, in
`prediction.metadata.trace`:

```elixir
for message <- prediction.metadata.trace.messages do
  IO.puts("#{message.role}:\n#{message.content}\n")
end
```

Imp wrote this system message from the signature:

```text
Your input fields are:
1. `ticket` (str):
Your output fields are:
1. `team` (Literal['atlas', 'harbor', 'beacon', 'quill']):
All interactions will be structured in the following way, with the appropriate values filled in.

Inputs will have the following structure:

[[ ## ticket ## ]]
{ticket}

Outputs will be a JSON object with the following fields.

{
  "team": "{team}        # note: the value you produce must exactly match (no extra characters) one of: atlas; harbor; beacon; quill"
}
In adhering to this structure, your objective is: 
        Route the support ticket to the squad that owns it.
```

and this user message from our input:

```text
[[ ## ticket ## ]]
We were charged twice this month.

Respond with a JSON object in the following order of fields: `team` (must be formatted as a valid Python Literal['atlas', 'harbor', 'beacon', 'quill']).
```

Imp renders signatures as DSPy's adapters do, down to the Python type names,
so what you know about DSPy's prompts holds here.

The model replied:

```elixir
prediction.metadata.trace.raw
#=> "{\"team\":\"harbor\"}"
```

We never wrote a prompt or a parser. We declared a task, and got back a value
we can use. [Adapters](../diving-deeper/adapters.md) explains how signatures
become messages and replies become fields.

To run this in a notebook, open
[Livebook 01](../../livebooks/01_real_lm_front_door.livemd) with a key, or
[Livebook 02](../../livebooks/02_without_a_provider.livemd) without one; 02
prints the exact messages Imp sends.

---

**Next:** [Expanding signatures →](expanding-signatures.md)

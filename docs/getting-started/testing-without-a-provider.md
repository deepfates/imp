# Testing without a provider

Our router will live inside an application, and the application's tests
shouldn't call a model: that is slow, costs money, and gives a different
answer on a bad day. `Imp.LM.Static` stands in for the model. We script what
it replies; everything else, from rendering the prompt to validating the
reply, runs for real.

```elixir
scripted = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end)

test_router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(lm: scripted, adapter: Imp.Adapter.JSON)

{:ok, prediction} = Imp.call(test_router, %{ticket: "We were charged twice this month."})
Imp.get(prediction, :team)
#=> "atlas"
```

This is the router from before with a different `lm:`. For a program we
already have, `Imp.with_lm(router, scripted)` makes the same swap.

The handler receives the messages Imp rendered, so a test can check what the
model would have been sent:

```elixir
echo =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "charged twice", do: %{team: "atlas"}, else: %{team: "quill"}
    end
  )

{:ok, prediction} =
  test_router
  |> Imp.with_lm(echo)
  |> Imp.call(%{ticket: "We were charged twice this month."})

Imp.get(prediction, :team)
#=> "atlas"
```

## Checking the contract

A handler can return fields, as above, or text, as a real model does. Text
goes through the adapter's parser, so we can test what happens when a model
misbehaves. Here the model names a team that doesn't exist:

```elixir
confused = Imp.LM.Static.new(handler: fn _messages, _opts -> ~s({"team": "billing"}) end)

result =
  test_router
  |> Imp.with_lm(confused)
  |> Imp.call(%{ticket: "We were charged twice this month."})

match?({:error, _reason}, result)
#=> true
```

The reply parsed as JSON but failed the signature, so the call returned an
error that carries the raw reply and the validation message. Code downstream
of the router never sees `"billing"`.

## Programs that read the model from context

A program built without `lm:` looks for one when it runs: first in
`Imp.context/2`, then in the default from `Imp.configure/1`. `Imp.context/2`
applies to the calling process only, so tests that use it can run with
`async: true`:

```elixir
unpinned =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.predict(adapter: Imp.Adapter.JSON)

{:ok, prediction} =
  Imp.context([lm: scripted], fn ->
    Imp.call(unpinned, %{ticket: "We were charged twice this month."})
  end)

Imp.get(prediction, :team)
#=> "atlas"
```

The blocks on this page are the bodies of ordinary ExUnit tests. They run in
milliseconds, and the rest of this guide leans on the same trick wherever a
model's answer isn't the point.

---

**Next:** [Tools and agents →](tools-and-agents.md)

# Changing the module

`Imp.predict/2` asks the model for the outputs directly. Other modules run the
same signature a different way. Let's ask the model to reason before it
answers:

```elixir
thinking_router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route the support ticket to the squad that owns it.")
  |> Imp.chain_of_thought(lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} = Imp.call(thinking_router, %{ticket: "We were charged twice this month."})
Imp.get(prediction, :team)
#=> "harbor"
```

The signature and the call are the same as the router's.
`Imp.chain_of_thought/2` adds a `reasoning` output in front of ours, so the
model writes out its thinking first, and we can read it:

```elixir
Imp.get(prediction, :reasoning)
#=> "The ticket reports a billing issue involving duplicate charges, which belongs to the payments/billing support team."
```

The reasoning is right, and the answer is still harbor. The model knows this
is a billing problem; it doesn't know that billing is atlas. Thinking longer
can't supply a fact the model was never given. One run can differ; measuring
comes later.

Changing the module never touches the signature. Other modules run it as a
tool-using agent, compare several attempts, or retry until a check passes; the
next pages use two of them, and
[Modules and composition](../diving-deeper/modules-and-composition.md) lists
the rest.

---

**Next:** [Testing without a provider →](testing-without-a-provider.md)

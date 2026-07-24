trainset = [
  {"Duplicate invoice charge", "atlas"},
  {"API outage in Europe", "harbor"},
  {"Password reset is blocked", "beacon"},
  {"How do I export a report?", "quill"}
]

held_out = [
  {"Refund the annual invoice", "atlas"},
  {"Dashboard latency is spiking", "harbor"},
  {"An old account can still sign in", "beacon"},
  {"Where are the import docs?", "quill"}
]

to_examples = fn rows ->
  Enum.map(rows, fn {ticket, team} ->
    Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
  end)
end

# This deterministic LM is a teaching fixture, not evidence about a real
# provider. Before it sees demonstrations it always chooses atlas. After the
# optimizer attaches one labeled example per opaque team, it can apply the
# illustrated routing convention to the held-out wording.
lm =
  Imp.LM.Static.new(
    handler: fn messages, _opts ->
      query =
        messages
        |> Enum.filter(&(&1.role == :user))
        |> List.last()
        |> Map.fetch!(:content)

      has_demos? = Enum.any?(messages, &(&1.role == :assistant))

      team =
        if has_demos? do
          cond do
            query =~ "invoice" or query =~ "Refund" -> "atlas"
            query =~ "latency" or query =~ "outage" -> "harbor"
            query =~ "account" or query =~ "Password" -> "beacon"
            query =~ "docs" or query =~ "How" -> "quill"
          end
        else
          "atlas"
        end

      %{team: team}
    end
  )

router =
  "ticket -> team: enum[atlas,harbor,beacon,quill]"
  |> Imp.signature("Route a support ticket to its owning internal team.")
  |> Imp.predict(lm: lm)

metric = Imp.exact_match(:team)
trainset = to_examples.(trainset)
held_out = to_examples.(held_out)

baseline = Imp.evaluate(router, held_out, metric)

compiled =
  Imp.optimize!(
    router,
    Imp.Optimizer.LabeledFewShot.new(k: 4),
    trainset
  )

optimized = Imp.evaluate(compiled, held_out, metric)

unless baseline.score == 0.25 and optimized.score == 1.0 do
  raise "unexpected tutorial scores: #{inspect(%{baseline: baseline, optimized: optimized})}"
end

unless length(compiled.demos) == 4 do
  raise "optimizer did not attach the four reviewable demonstrations"
end

typed_output? =
  case compiled.signature.outputs do
    [%{name: :team, metadata: %{constraints: %{enum: teams}}}] ->
      teams == ["atlas", "harbor", "beacon", "quill"]

    _other ->
      false
  end

unless typed_output? do
  raise "compiled program lost the typed output contract"
end

IO.puts("provider-free tutorial passed: 25% -> 100%")
IO.puts("typed output: enum[atlas,harbor,beacon,quill]")
IO.puts("compiled demonstrations: #{length(compiled.demos)}")

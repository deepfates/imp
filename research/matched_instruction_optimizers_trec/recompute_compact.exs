# Recomputes the matched TREC aggregate from the committed scored rows and
# prints what it computed. Every number this prints is derived here, in this
# process, from the row files named on the command line. Nothing is a literal.
#
# Exits 1 if the recomputed aggregate disagrees with the committed one, naming
# the three headline quantities on both sides so the disagreement is legible
# without opening the JSON.
#
# This recomputes statistics. It does not reproduce the experiment: the raw
# provider responses behind these rows were not published. See
# research/CASE_STUDY_TREC.md.

Code.require_file("contract.exs", __DIR__)
Code.require_file("aggregate.exs", __DIR__)

alias MatchedInstructionOptimizersTREC.Aggregator

argv =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

format = fn
  nil -> "n/a"
  value when is_float(value) -> :erlang.float_to_binary(value, decimals: 4)
  value -> to_string(value)
end

signed = fn
  nil -> "n/a"
  value when is_float(value) and value >= 0 -> "+" <> :erlang.float_to_binary(value, decimals: 4)
  value when is_float(value) -> :erlang.float_to_binary(value, decimals: 4)
  value -> to_string(value)
end

interval = fn
  [low, high] -> "[#{format.(low)}, #{format.(high)}]"
  _ -> "[n/a]"
end

headlines = fn aggregate ->
  acceptance = Map.get(aggregate, "acceptance", %{})
  improvements = Map.get(acceptance, "improvements", %{})
  gepa = Map.get(improvements, "gepa", %{})
  mipro = Map.get(improvements, "mipro_v2", %{})
  matched = Map.get(acceptance, "winning_optimizer_imp_minus_upstream", %{})

  [
    {"GEPA over its own baseline", gepa},
    {"MIPROv2 over its own baseline", mipro},
    {"GEPA Imp minus DSPy", matched}
  ]
end

report = fn label, aggregate ->
  IO.puts("#{label}:")

  for {name, stats} <- headlines.(aggregate) do
    IO.puts(
      "  #{name}: #{signed.(Map.get(stats, "mean"))} " <>
        "95% CI #{interval.(Map.get(stats, "confidence_interval"))}" <>
        case Map.get(stats, "holm_adjusted_p") do
          nil -> ""
          p -> ", Holm-adjusted p = #{:erlang.float_to_binary(p, decimals: 5)}"
        end
    )
  end
end

case argv do
  [manifest, imp_rows, upstream_rows, expected_aggregate] ->
    recomputed = Aggregator.aggregate!(manifest, imp_rows, upstream_rows)
    expected = expected_aggregate |> File.read!() |> Jason.decode!()

    report.(
      "Recomputed from #{Path.basename(imp_rows)} and #{Path.basename(upstream_rows)}",
      recomputed
    )

    if recomputed == expected do
      acceptance = Map.get(recomputed, "acceptance", %{})

      IO.puts(
        "  noninferiority margin #{format.(Map.get(acceptance, "noninferiority_margin"))}, " <>
          "winning optimizer #{Map.get(acceptance, "winning_optimizer", "n/a")}, " <>
          "headline passed: #{Map.get(acceptance, "headline_passed", "n/a")}"
      )

      IO.puts("")
      IO.puts("Recomputation agrees with #{Path.basename(expected_aggregate)} in full.")
    else
      IO.puts("")
      report.("Committed in #{Path.basename(expected_aggregate)}", expected)

      IO.puts("")

      IO.puts(
        "MISMATCH: the recomputed aggregate differs from the committed one. " <>
          "Either the scored rows changed or the aggregation did; both are bugs."
      )

      System.halt(1)
    end

  _ ->
    IO.puts(
      :stderr,
      "usage: mix run --no-start recompute_compact.exs -- MANIFEST IMP_ROWS UPSTREAM_ROWS EXPECTED_AGGREGATE"
    )

    System.halt(2)
end

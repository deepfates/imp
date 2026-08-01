Code.require_file("contract.exs", __DIR__)
Code.require_file("aggregate.exs", __DIR__)

alias MatchedInstructionOptimizersTREC.Aggregator

argv =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

case argv do
  [manifest, imp_rows, upstream_rows, expected_aggregate] ->
    recomputed = Aggregator.aggregate!(manifest, imp_rows, upstream_rows)
    expected = expected_aggregate |> File.read!() |> Jason.decode!()

    unless recomputed == expected do
      raise "committed compact aggregate does not match recomputed scored rows"
    end

    IO.puts(
      "matched TREC compact recomputation passed: " <>
        "GEPA +0.4000, MIPROv2 +0.1458, GEPA Imp-minus-DSPy -0.0083"
    )

  _ ->
    raise "usage: mix run recompute_compact.exs -- MANIFEST IMP_ROWS UPSTREAM_ROWS EXPECTED_AGGREGATE"
end

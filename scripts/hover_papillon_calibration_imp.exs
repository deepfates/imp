alias Imp.BenchmarkTruth.HoverPapillonCalibration, as: Pilot

initial_actual_cost_usd =
  case System.get_env("IMP_CALIBRATION_INITIAL_COST_USD", "0") |> Float.parse() do
    {value, ""} when value >= 0 -> value
    _other -> raise "IMP_CALIBRATION_INITIAL_COST_USD must be a nonnegative number"
  end

case System.argv() do
  ["--provider-disabled", root] ->
    result =
      Pilot.run_provider_disabled!(Path.expand(root),
        initial_actual_cost_usd: initial_actual_cost_usd
      )

    IO.puts(Jason.encode!(%{status: result.mode, transports: result.summary.transport_count}))

  ["--live", root] ->
    Pilot.candidate_identity!(System.get_env("IMP_CALIBRATION_EXPECTED_COMMIT"))
    Pilot.live_preflight!()
    catalog = Pilot.current_catalog!()

    result =
      Pilot.run_live!(Path.expand(root), catalog,
        initial_actual_cost_usd: initial_actual_cost_usd
      )

    IO.puts(Jason.encode!(%{status: result.mode, transports: result.summary.transport_count}))

  _ ->
    raise "usage: mix run scripts/hover_papillon_calibration_imp.exs --provider-disabled OUTPUT_ROOT | --live OUTPUT_ROOT"
end

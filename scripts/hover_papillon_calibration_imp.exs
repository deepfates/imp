alias Imp.BenchmarkTruth.HoverPapillonCalibration, as: Pilot

case System.argv() do
  ["--provider-disabled", root] ->
    result = Pilot.run_provider_disabled!(Path.expand(root))
    IO.puts(Jason.encode!(%{status: result.mode, transports: result.summary.transport_count}))

  ["--live", _root] ->
    Pilot.candidate_identity!(System.get_env("IMP_CALIBRATION_EXPECTED_COMMIT"))
    Pilot.live_preflight!()

    raise "live execution is intentionally disabled until independent review grants provider authority"

  _ ->
    raise "usage: mix run scripts/hover_papillon_calibration_imp.exs --provider-disabled OUTPUT_ROOT | --live OUTPUT_ROOT"
end

Code.require_file("contract.exs", __DIR__)

alias MatchedGepaMiproIFBenchV3.Contract

expected_cwd = Path.expand(__DIR__)
actual_cwd = File.cwd!()

unless actual_cwd == expected_cwd do
  raise "paired Imp preflight must run from #{expected_cwd}, got #{actual_cwd}"
end

manifest = Contract.load_optimization!(Path.join(__DIR__, "contract.json"))
expected = manifest["runtime_dependencies"]["imp"]

actual_packages =
  Map.new(expected["packages"], fn {name, _expected_version} ->
    app = String.to_existing_atom(name)

    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, reason} -> raise "could not load dependency #{name}: #{inspect(reason)}"
    end

    version = Application.spec(app, :vsn) || raise "dependency #{name} has no application version"
    {name, to_string(version)}
  end)

unless actual_packages == expected["packages"] do
  raise "paired Imp dependency drift: #{inspect(actual_packages)}"
end

unless System.version() == expected["elixir"] and
         :erlang.system_info(:otp_release) |> List.to_string() == expected["otp"] do
  raise "paired Imp Elixir/OTP runtime drift"
end

report = %{
  status: "pass",
  cwd: actual_cwd,
  manifest_sha256: manifest["manifest_sha256"],
  packages: actual_packages,
  provider_authority_present: not is_nil(System.get_env("OPENROUTER_API_KEY")),
  held_out_loaded: false,
  source_commit:
    case System.cmd("git", ["-C", Path.expand("../..", __DIR__), "rev-parse", "HEAD"]) do
      {commit, 0} -> String.trim(commit)
      {output, status} -> raise "git rev-parse failed (#{status}): #{output}"
    end
}

expected_commit =
  System.get_env("MATCHED_IFBENCH_V3_EXPECTED_COMMIT") ||
    raise "MATCHED_IFBENCH_V3_EXPECTED_COMMIT is required"

unless report.source_commit == expected_commit do
  raise "v3 launch commit drift: #{report.source_commit} != #{expected_commit}"
end

IO.puts("PAIRED_PREFLIGHT_JSON=" <> Jason.encode!(report))

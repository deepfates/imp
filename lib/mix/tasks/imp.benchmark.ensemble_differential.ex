defmodule Mix.Tasks.Imp.Benchmark.EnsembleDifferential do
  @moduledoc "Capture provider-free Ensemble C1 differential evidence."

  use Mix.Task

  @shortdoc "Capture provider-free Ensemble C1 evidence"
  @protocol_id "ensemble-c1-v1"
  @registry_protocol_id "ensemble_differential"
  @family_id "family.optimizer_ensemble"
  @task_path "lib/mix/tasks/imp.benchmark.ensemble_differential.ex"
  @script_path "scripts/dspy_ensemble_differential.py"
  @config_path "benchmarks/config/ensemble-differential-v1.json"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @ledger_path "benchmarks/authorities.json"
  @imp_source_path "lib/imp/optimizer/ensemble.ex"
  @dspy_source "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"

  defmodule FixtureProgram do
    @moduledoc false
    @behaviour Imp.Module
    defstruct [:value]

    @impl true
    def call(%__MODULE__{value: value}, _inputs),
      do: {:ok, Imp.Prediction.new(%{value: value})}
  end

  @impl true
  def run(args), do: run_with_runner(args, nil)

  @doc false
  def run_with_runner(args, runner)
      when is_list(args) and (is_nil(runner) or is_function(runner, 0)) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [out: :string, python: :string, require_clean: :boolean])

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")

    unless Keyword.get(opts, :require_clean, true) do
      Mix.raise("Ensemble C1 evidence cannot be captured without --require-clean")
    end

    validate_fixture_authority!()
    bindings = source_bindings()

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: true,
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@dspy_commit}"},
        inputs: bindings
      )

    report =
      if runner,
        do: runner.(),
        else: run_python!(Keyword.get(opts, :python, default_python()))

    artifact = build_artifact!(report, bindings)
    out = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("ensemble-differential"))
    File.mkdir_p!(out)

    name =
      Imp.BenchmarkTruth.ArtifactFile.artifact_name(
        "ensemble-differential",
        [fixture()["fixture_id"]]
      )

    %{artifact: written, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(Path.join(out, name), artifact, context)

    validate_artifact!(@registry_protocol_id, written)
    Mix.shell().info("Ensemble provider-free C1 differential artifact: #{path}")
  end

  @doc false
  def build_artifact!(report, bindings \\ source_bindings()) when is_map(report) do
    validate_fixture_authority!()
    validate_report!(report)
    local = local_observations()
    upstream = report["observations"]
    shared_keys = ~w(all_program_count reduced_mean subset_count)
    upstream_shared = Map.take(upstream, shared_keys)

    unless local["shared"] == upstream_shared do
      raise ArgumentError, "Imp Ensemble observations differ from pinned DSPy observations"
    end

    %{
      "schema_version" => 1,
      "protocol_id" => @protocol_id,
      "registry_protocol_id" => @registry_protocol_id,
      "family" => "ensemble",
      "evidence_tier" => "C1",
      "status" => "passing",
      "provider_free" => true,
      "source_bindings" => bindings,
      "scope" => fixture()["scope"],
      "comparison" => %{
        "dspy" => upstream_shared,
        "imp" => local["shared"],
        "matched" => true
      },
      "native_extensions" => %{
        "dspy_rejects_deterministic" => upstream["dspy_rejects_deterministic"],
        "imp_deterministic_replay_supported" => local["deterministic_replay_supported"]
      },
      "dspy_receipt" => report,
      "summary" => %{
        "authenticated_dspy_commit" => @dspy_commit,
        "matched_claim_count" => length(get_in(fixture(), ["scope", "claims"])),
        "retained_exclusions" => get_in(fixture(), ["scope", "not_claimed"])
      }
    }
  end

  @doc false
  def validate_artifact!(@registry_protocol_id, artifact) when is_map(artifact) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    bindings = source_bindings()

    unless get_in(artifact, ["run_context", "workspace", "state"]) == "clean" do
      raise ArgumentError, "Ensemble C1 admission requires a clean checkout"
    end

    unless committed_sources_match?(artifact["git_sha"], bindings) and
             get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings do
      raise ArgumentError, "Ensemble C1 artifact is not bound to committed Imp source"
    end

    expected = build_artifact!(artifact["dspy_receipt"], bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected do
      raise ArgumentError, "Ensemble C1 artifact content does not recompute"
    end

    artifact
  end

  def validate_artifact!(protocol_id, _artifact),
    do: raise(ArgumentError, "unknown Ensemble protocol #{inspect(protocol_id)}")

  @doc false
  def local_observations do
    fixture = fixture()["fixture"]
    programs = Enum.map(fixture["program_values"], &%FixtureProgram{value: &1})

    {:ok, all} =
      Imp.Optimizer.Ensemble.new()
      |> Imp.Optimizer.Ensemble.compile(programs)
      |> Imp.Module.call(%{})

    reducer = fn predictions ->
      values = Enum.map(predictions, &Imp.get(&1, :value))
      %{mean: Enum.sum(values) / length(values)}
    end

    {:ok, reduced} =
      Imp.Optimizer.Ensemble.new(reduce_fn: reducer)
      |> Imp.Optimizer.Ensemble.compile(programs)
      |> Imp.Module.call(%{})

    subset_programs =
      Enum.map(fixture["subset_program_values"], &%FixtureProgram{value: &1})

    {:ok, subset} =
      Imp.Optimizer.Ensemble.new(size: fixture["subset_size"], seed: 17)
      |> Imp.Optimizer.Ensemble.compile(subset_programs)
      |> Imp.Module.call(%{})

    {:ok, deterministic} =
      Imp.Optimizer.Ensemble.new(deterministic: true)
      |> Imp.Optimizer.Ensemble.compile(programs)
      |> Imp.Module.call(%{})

    %{
      "shared" => %{
        "all_program_count" => length(Imp.get(all, :outputs)),
        "reduced_mean" => Imp.get(reduced, :mean),
        "subset_count" => length(Imp.get(subset, :outputs))
      },
      "deterministic_replay_supported" => is_list(Imp.get(deterministic, :outputs))
    }
  end

  @doc false
  def source_bindings do
    %{
      "protocol_id" => @protocol_id,
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "config_sha256" => file_sha256!(@config_path),
      "authority_manifest_sha256" => file_sha256!(@authority_path),
      "authority_family_sha256" => family_sha256!(File.read!(@ledger_path)),
      "imp_optimizer_source_sha256" => file_sha256!(@imp_source_path),
      "dspy_commit" => @dspy_commit
    }
  end

  @doc false
  def credential_safe_python_env do
    removals =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&credential_env_name?/1)
      |> Enum.map(&{&1, nil})

    removals ++
      [
        {"PYTHONPATH", Path.expand(@dspy_source)},
        {"PYTHON_DOTENV_DISABLED", "1"},
        {"DOTENV_DISABLED", "1"},
        {"PYTHONNOUSERSITE", "1"},
        {"HOME", System.tmp_dir!()}
      ]
  end

  defp validate_report!(report) do
    expected = fixture()["fixture"]["expected"]

    unless report == %{
             "schema_version" => 1,
             "fixture_id" => fixture()["fixture_id"],
             "status" => "passing",
             "provider_free" => true,
             "credential_environment" => %{"provider_credential_names_present" => []},
             "runtime_identity" => %{
               "git_commit" => @dspy_commit,
               "git_clean" => true,
               "distribution_version" => "3.2.1"
             },
             "observations" => expected
           } do
      raise ArgumentError, "Ensemble sidecar receipt is invalid"
    end
  end

  defp validate_fixture_authority! do
    config = fixture()
    source = config["source"]
    manifest = read_json!(@authority_path)
    ledger = read_json!(@ledger_path)
    family = Enum.find(ledger["families"], &(&1["id"] == @family_id))
    repository = family && family["upstream_repository"]

    unless source["commit"] == @dspy_commit and manifest["commit"] == @dspy_commit and
             Map.take(source, ~w(repository version git_ref commit source_manifest)) ==
               Map.take(repository || %{}, ~w(repository version git_ref commit source_manifest)) and
             source["source_manifest"]["sha256"] == raw_file_sha256!(@authority_path) and
             source["source_manifest"]["file_count"] == length(manifest["files"] || []) do
      raise ArgumentError, "Ensemble fixture is not bound to canonical DSPy authority"
    end

    manifest_files = Map.new(manifest["files"], &{&1["path"], &1["sha256"]})

    ensemble_source = source["ensemble_source"]

    unless manifest_files[ensemble_source["path"]] == ensemble_source["sha256"] do
      raise ArgumentError, "Ensemble source is absent from the DSPy authority manifest"
    end

    references = get_in(family, ["upstream_tests", "references"]) || []
    test = source["upstream_test"]

    unless "#{test["path"]}#sha256=#{test["sha256"]}" in references do
      raise ArgumentError, "Ensemble upstream test is absent from the authority ledger"
    end

    unless raw_file_sha256!(Path.join(@dspy_source, test["path"])) == test["sha256"] do
      raise ArgumentError, "Ensemble upstream test differs from the pinned authority hash"
    end

    Enum.each(manifest["files"], fn entry ->
      path = Path.join(@dspy_source, entry["path"])

      unless File.regular?(path) and raw_file_sha256!(path) == entry["sha256"] do
        raise ArgumentError, "DSPy authority materialization differs at #{entry["path"]}"
      end
    end)
  end

  defp run_python!(python) do
    case System.cmd(
           python,
           [Path.expand(@script_path), "--config", Path.expand(@config_path)],
           cd: File.cwd!(),
           env: credential_safe_python_env(),
           stderr_to_stdout: false
         ) do
      {output, 0} -> Jason.decode!(output)
      {output, status} -> Mix.raise("Ensemble sidecar failed #{status}: #{output}")
    end
  end

  defp committed_sources_match?(git_sha, bindings) when is_binary(git_sha) do
    files = [
      {@task_path, "task_sha256"},
      {@script_path, "script_sha256"},
      {@config_path, "config_sha256"},
      {@authority_path, "authority_manifest_sha256"},
      {@imp_source_path, "imp_optimizer_source_sha256"}
    ]

    family_matches =
      case System.cmd("git", ["show", "#{git_sha}:#{@ledger_path}"], stderr_to_stdout: true) do
        {bytes, 0} -> family_sha256!(bytes) == bindings["authority_family_sha256"]
        _ -> false
      end

    Regex.match?(~r/^[0-9a-f]{40}$/, git_sha) and family_matches and
      Enum.all?(files, fn {path, key} ->
        case System.cmd("git", ["show", "#{git_sha}:#{path}"], stderr_to_stdout: true) do
          {bytes, 0} -> "sha256:" <> raw_sha256(bytes) == bindings[key]
          _ -> false
        end
      end)
  end

  defp committed_sources_match?(_, _), do: false

  defp family_sha256!(ledger_bytes) do
    ledger = Jason.decode!(ledger_bytes)
    family = Enum.find(ledger["families"], &(&1["id"] == @family_id))
    unless family, do: raise(ArgumentError, "missing #{@family_id} authority")
    "sha256:" <> raw_sha256(Imp.Training.ChatDataset.canonical_json(family))
  end

  defp fixture, do: read_json!(@config_path)
  defp default_python, do: Path.expand("tmp/dspy-parity-venv/bin/python")
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp file_sha256!(path), do: "sha256:" <> raw_file_sha256!(path)
  defp raw_file_sha256!(path), do: path |> File.read!() |> raw_sha256()
  defp raw_sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp credential_env_name?(name) do
    upper = String.upcase(name)

    upper == "PGPASSWORD" or
      Enum.any?(
        ~w(API_KEY ACCESS_KEY ACCESS_TOKEN AUTHORIZATION AUTH_TOKEN BEARER_TOKEN CLIENT_SECRET CREDENTIAL CREDENTIALS DATABASE_URL PASSWORD PRIVATE_KEY SECRET SECRET_KEY TOKEN COOKIE CONNECTION_STRING),
        &(upper == &1 or String.ends_with?(upper, "_" <> &1))
      )
  end
end

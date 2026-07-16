defmodule Mix.Tasks.Imp.Benchmark.CoproIsolation do
  @moduledoc """
  Capture the provider-free, pinned DSPy COPRO isolation differential as C1 evidence.

      mix imp.benchmark.copro_isolation --require-clean

  Artifact admission is receipt-only by default: it verifies the run envelope,
  current Imp source bindings, the authenticated DSPy authority materialization,
  exact deterministic observations, and the retained scope exclusions. Pass
  `fresh_replay: true` to `validate_artifact!/2` only when an explicit replay is
  wanted.
  """

  use Mix.Task

  @shortdoc "Capture provider-free COPRO C1 isolation evidence"
  @protocol_id "copro-isolation-c1-v1"
  @task_path "lib/mix/tasks/imp.benchmark.copro_isolation.ex"
  @script_path "scripts/dspy_copro_isolation_differential.py"
  @config_path "benchmarks/config/copro-isolation-differential-v1.json"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @ledger_path "benchmarks/authorities.json"
  @imp_source_path "lib/imp/optimizer/copro.ex"
  @dspy_source "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @required_exclusions [
    "exact Python RNG parity",
    "provider behavior or effectiveness",
    "full optimizer parity"
  ]

  @impl true
  def run(args), do: run_with_runner(args, nil)

  @doc false
  def run_with_runner(args, runner)
      when is_list(args) and (is_nil(runner) or is_function(runner, 0)) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, python: :string, require_clean: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")

    unless Keyword.get(opts, :require_clean, true) do
      Mix.raise("COPRO C1 evidence cannot be captured without --require-clean")
    end

    fixture = read_json!(@config_path)
    bindings = source_bindings()
    validate_fixture_authority!(fixture)

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: true,
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@dspy_commit}"},
        inputs: bindings
      )

    report =
      if runner, do: runner.(), else: run_python!(Keyword.get(opts, :python, default_python()))

    artifact = build_artifact!(report, bindings)

    out_dir =
      Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("copro-isolation"))

    File.mkdir_p!(out_dir)

    name =
      Imp.BenchmarkTruth.ArtifactFile.artifact_name("copro-isolation", [fixture["fixture_id"]])

    %{artifact: written, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(Path.join(out_dir, name), artifact, context)

    validate_artifact!(written)
    Mix.shell().info("COPRO provider-free C1 isolation artifact: #{path}")
  end

  @doc false
  def build_artifact!(report, bindings \\ source_bindings())
      when is_map(report) and is_map(bindings) do
    fixture = read_json!(@config_path)
    validate_fixture_authority!(fixture)
    validate_report!(report, fixture)

    %{
      "schema_version" => 1,
      "protocol_id" => @protocol_id,
      "evidence_tier" => "C1",
      "status" => "passing",
      "provider_free" => true,
      "source_bindings" => bindings,
      "scope" => fixture["scope"],
      "dspy_report" => report,
      "summary" => %{
        "authenticated_dspy_commit" => @dspy_commit,
        "deterministic_observations_verified" => 5,
        "retained_exclusions" => @required_exclusions
      }
    }
  end

  @doc """
  Validate an artifact without executing either implementation.

  Set `fresh_replay: true` to separately execute and compare a fresh pinned
  provider-free Python receipt after pure validation succeeds.
  """
  def validate_artifact!(artifact, opts \\ []) when is_map(artifact) and is_list(opts) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    fixture = read_json!(@config_path)
    bindings = source_bindings()
    validate_fixture_authority!(fixture)

    unless get_in(artifact, ["run_context", "workspace", "state"]) == "clean" do
      raise ArgumentError,
            "COPRO C1 admission requires an artifact captured from a clean checkout"
    end

    unless artifact["git_sha"] == current_git_sha!() and
             get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings do
      raise ArgumentError, "COPRO C1 artifact is not bound to the current committed Imp source"
    end

    expected = build_artifact!(artifact["dspy_report"], bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected do
      raise ArgumentError, "COPRO C1 artifact content does not recompute"
    end

    if Keyword.get(opts, :fresh_replay, false) do
      replay = run_python!(Keyword.get(opts, :python, default_python()))

      unless replay == artifact["dspy_report"] do
        raise ArgumentError, "COPRO C1 fresh replay differs from the admitted receipt"
      end
    end

    artifact
  end

  @doc false
  def source_bindings do
    %{
      "protocol_id" => @protocol_id,
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "config_sha256" => file_sha256!(@config_path),
      "authority_manifest_sha256" => file_sha256!(@authority_path),
      "authority_ledger_sha256" => file_sha256!(@ledger_path),
      "imp_copro_source_sha256" => file_sha256!(@imp_source_path),
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

  defp run_python!(python) do
    case System.cmd(
           python,
           [Path.expand(@script_path), "--config", Path.expand(@config_path)],
           cd: File.cwd!(),
           env: credential_safe_python_env(),
           stderr_to_stdout: true
         ) do
      {output, 0} -> Jason.decode!(output)
      {output, status} -> Mix.raise("COPRO isolation sidecar failed #{status}: #{output}")
    end
  end

  defp validate_fixture_authority!(fixture) do
    source = fixture["source"]
    manifest_reference = source["source_manifest"]
    manifest = read_json!(@authority_path)
    ledger = read_json!(@ledger_path)

    family = Enum.find(ledger["families"], &(&1["id"] == source["authority_family"]))
    canonical = family && family["upstream_repository"]

    identity_fields = ~w(repository version git_ref commit source_manifest)

    unless is_map(canonical) and
             Map.take(source, identity_fields) == Map.take(canonical, identity_fields) and
             source["commit"] == @dspy_commit and manifest["commit"] == @dspy_commit and
             manifest_reference["path"] == @authority_path and
             manifest_reference["sha256"] == raw_file_sha256!(@authority_path) and
             manifest_reference["file_count"] == length(manifest["files"] || []) do
      raise ArgumentError, "COPRO fixture is not bound to the canonical DSPy authority"
    end

    manifest_files = Map.new(manifest["files"], &{&1["path"], &1["sha256"]})

    unless manifest_files[source["copro_source"]["path"]] == source["copro_source"]["sha256"] do
      raise ArgumentError, "COPRO source hash is absent from the authority manifest"
    end

    references = get_in(family, ["upstream_tests", "references"]) || []

    test_reference =
      "#{source["upstream_test"]["path"]}#sha256=#{source["upstream_test"]["sha256"]}"

    unless test_reference in references,
      do: raise(ArgumentError, "COPRO upstream test is absent from the authority ledger")
  end

  defp validate_report!(report, fixture) do
    source = fixture["source"]
    observations = report["observations"]
    runtime = report["runtime_identity"]

    required_top_level =
      ~w(credential_environment fixture_id fixture_identity isolation observations runner runtime_identity schema_version scope source status)

    unless Map.keys(report) |> Enum.sort() == required_top_level |> Enum.sort() and
             report["schema_version"] == 1 and report["fixture_id"] == fixture["fixture_id"] and
             report["status"] == "passing" and
             report["runner"] == "python-dspy-copro-isolation-differential" and
             report["source"] == source and report["scope"] == fixture["scope"] and
             report["credential_environment"] == %{"provider_credential_names_present" => []} do
      raise ArgumentError, "COPRO sidecar receipt identity or scope is invalid"
    end

    validate_runtime!(runtime, source)
    validate_isolation!(report["isolation"])
    validate_fixture_identity!(report["fixture_identity"])
    validate_observations!(observations, fixture)

    exclusions = report["scope"]["not_claimed"] || []

    unless Enum.sort(exclusions) == Enum.sort(@required_exclusions) do
      raise ArgumentError,
            "COPRO C1 evidence must retain exact RNG/provider/effectiveness/full-parity exclusions"
    end
  end

  defp validate_runtime!(runtime, source) do
    expected = %{
      "authority_ledger_sha256" => raw_file_sha256!(@ledger_path),
      "authority_manifest_sha256" => raw_file_sha256!(@authority_path),
      "authority_manifest_verified_files" => source["source_manifest"]["file_count"],
      "distribution_version" => source["version"],
      "git_clean" => true,
      "git_commit" => @dspy_commit,
      "git_tag" => source["version"],
      "module_version" => "3.2.0"
    }

    unless runtime == Map.put(expected, "source_root", @dspy_source) do
      raise ArgumentError, "COPRO sidecar did not authenticate the pinned clean DSPy 3.2.1 source"
    end
  end

  defp validate_isolation!(isolation) do
    unless isolation == %{
             "isolated_process" => true,
             "parent_poison_model" => "fake/poisoned-parent-state",
             "poison_marker_seen" => false,
             "worker_lm_model" => "fake/copro-isolation-fixture"
           } do
      raise ArgumentError, "COPRO process isolation receipt is invalid"
    end
  end

  defp validate_fixture_identity!(identity) do
    unless identity == %{
             "script_sha256" => raw_file_sha256!(@script_path),
             "config_sha256" => raw_file_sha256!(@config_path)
           } do
      raise ArgumentError, "COPRO fixture receipt has stale script or config identity"
    end
  end

  defp validate_observations!(observations, fixture) do
    copro = fixture["copro"]
    proposals = fixture["proposals"]
    proposal_responses = Enum.with_index(proposals, &proposal_receipt/2)

    expected_exact = %{
      "proposal_request_count" => 1,
      "proposal_n" => [copro["breadth"] - 1],
      "proposal_order" => copro["proposal_order"],
      "proposal_call_history" => [
        %{
          "history_index" => 0,
          "requested_n" => copro["breadth"] - 1,
          "response_choice_count" => length(proposals),
          "responses" => proposal_responses
        }
      ],
      "lm_history_call_count" => copro["total_calls"] + 1,
      "evaluation_order" => copro["evaluation_order"],
      "candidate_program_order" => copro["candidate_program_order"],
      "candidate_programs" => expected_candidate_programs(fixture),
      "candidate_program_count" => copro["candidate_program_count"],
      "total_calls" => copro["total_calls"]
    }

    unless Map.drop(observations, ["results_latest", "results_best"]) == expected_exact do
      raise ArgumentError, "COPRO deterministic call/order/deduplication observations are invalid"
    end

    validate_stats!(observations["results_latest"], copro["results_latest"])
    validate_stats!(observations["results_best"], copro["results_best"])
  end

  defp expected_candidate_programs(fixture) do
    scores = fixture["copro"]["scores"]

    [
      %{
        "depth" => 0,
        "instruction" => "Candidate B",
        "key" => "candidate_b",
        "prefix" => "B:",
        "score" => scores["candidate_b"] * 100
      },
      %{
        "depth" => 0,
        "instruction" => "Candidate A",
        "key" => "candidate_a",
        "prefix" => "A:",
        "score" => scores["candidate_a"] * 100
      },
      %{
        "depth" => 0,
        "instruction" => "Answer the fixture question.",
        "key" => "base",
        "prefix" => "Answer:",
        "score" => scores["base"] * 100
      }
    ]
  end

  defp proposal_receipt(proposal, index) do
    response =
      "[[ ## proposed_instruction ## ]]\n#{proposal["instruction"]}\n" <>
        "[[ ## proposed_prefix_for_output_field ## ]]\n#{proposal["prefix"]}\n" <>
        "[[ ## completed ## ]]"

    %{
      "choice_index" => index,
      "instruction" => proposal["instruction"],
      "prefix" => proposal["prefix"],
      "response_sha256" => raw_sha256(response)
    }
  end

  defp validate_stats!(actual, expected) when is_map(actual) and is_map(expected) do
    unless actual["depth"] == expected["depth"] and
             Enum.all?(~w(max average min std), fn key ->
               values_close?(actual[key], expected[key])
             end) do
      raise ArgumentError, "COPRO statistics differ from the preregistered fixture"
    end
  end

  defp validate_stats!(_actual, _expected),
    do: raise(ArgumentError, "COPRO statistics are missing")

  defp values_close?(actual, expected)
       when is_list(actual) and is_list(expected) and
              length(actual) == length(expected) do
    Enum.zip(actual, expected)
    |> Enum.all?(fn {left, right} ->
      is_number(left) and is_number(right) and abs(left - right) < 1.0e-12
    end)
  end

  defp values_close?(_actual, _expected), do: false

  defp credential_env_name?(name) do
    upper = String.upcase(name)

    upper == "PGPASSWORD" or
      Enum.any?(
        ~w(API_KEY ACCESS_KEY ACCESS_TOKEN AUTHORIZATION AUTH_TOKEN BEARER_TOKEN CLIENT_SECRET CREDENTIAL CREDENTIALS DATABASE_URL PASSWORD PRIVATE_KEY SECRET SECRET_KEY TOKEN COOKIE CONNECTION_STRING),
        &(upper == &1 or String.ends_with?(upper, "_" <> &1))
      )
  end

  defp current_git_sha! do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      {_output, _status} -> raise ArgumentError, "cannot resolve current Imp source revision"
    end
  end

  defp default_python, do: Path.expand("tmp/dspy-parity-venv/bin/python")
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp file_sha256!(path), do: "sha256:" <> raw_file_sha256!(path)
  defp raw_file_sha256!(path), do: path |> File.read!() |> raw_sha256()

  defp raw_sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

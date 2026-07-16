defmodule Mix.Tasks.Imp.Benchmark.BfclAdapted do
  @moduledoc "Run the source-bound BFCL-shaped scorer conformance check."

  use Mix.Task

  @shortdoc "Run independent BFCL-shaped scorer conformance"
  @config_path "benchmarks/config/bfcl-adapted-differential-v1.json"
  @task_path "lib/mix/tasks/imp.benchmark.bfcl_adapted.ex"
  @script_path "scripts/bfcl_adapted_reference_scorer.py"
  @authority_path "benchmarks/authority_sources/bfcl-protocol-6ea5797.json"
  @bfcl_commit "6ea57973c7a6097fd7c5915698c54c17c5b1b6c8"
  @bfcl_repository "https://github.com/ShishirPatil/gorilla"
  @terminals ~w(submitted max_iters tool_error unknown_tool)
  @score_keys ~w(valid_input tool_name_exact arguments_exact terminal_state_exact passing error_code)
  @core_keys ~w(schema_version protocol_id evidence_level source_bindings imp reference rows mutations summary adaptations_and_deviations limitations)
  @artifact_keys Enum.sort(@core_keys ++ ~w(generated_at git_sha run_context))
  @authority_files %{
    "berkeley-function-call-leaderboard/README.md" =>
      "c6c95683cce9653788c8b3f3f5002d2f5c27b95a1288544fe82c2a2faf5e12d0",
    "berkeley-function-call-leaderboard/bfcl_eval/eval_checker/ast_eval/ast_checker.py" =>
      "2aae7a68461a8f76c0be3894c8901b66b56967a1989d3ab066051e3fb97f1538",
    "berkeley-function-call-leaderboard/bfcl_eval/eval_checker/eval_runner.py" =>
      "b1033684908819ccb312d4d0e2c563359d69247412f00206013b2292b0e3ce81"
  }

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, python: :string, require_clean: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")
    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config, bindings)

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, false),
        source_commits: %{"bfcl_protocol" => "ShishirPatil/gorilla@#{@bfcl_commit}"},
        inputs: bindings
      )

    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("bfcl-adapted"))
    File.mkdir_p!(out_dir)
    imp = imp_report(config)
    reference = run_reference!(Keyword.get(opts, :python, default_python()), out_dir)
    artifact = compare_reports!(imp, reference)
    path = Path.join(out_dir, "bfcl-shaped-conformance-#{timestamp_slug()}.json")

    %{artifact: artifact, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, artifact, context)

    Mix.shell().info("BFCL-shaped scorer conformance report: #{path}")

    Mix.shell().info(
      "matched positives/mutations: #{artifact["summary"]["matched_positive_rows"]}/12, " <>
        "#{artifact["summary"]["matched_mutation_rows"]}/9"
    )

    unless artifact["summary"]["fixture_scorer_conformance_complete"] do
      Mix.raise("BFCL-shaped scorer conformance failed; inspect #{path}")
    end
  end

  @doc false
  def compare_reports!(imp, reference) do
    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config, bindings)

    unless reference["source"] == reference_source(bindings) and
             valid_python_runtime?(reference["runtime"]) and
             reference["runner"] == "independent-python-bfcl-shaped-scorer" do
      Mix.raise("BFCL-shaped reference report has stale or wrong source/runtime bindings")
    end

    assert_exact_ids!(imp["rows"], reference["rows"], fixture_ids(config, "cases"), "positive")

    assert_exact_ids!(
      imp["mutations"],
      reference["mutations"],
      fixture_ids(config, "mutations"),
      "mutation"
    )

    rows = compare_rows(imp["rows"], reference["rows"])
    mutations = compare_rows(imp["mutations"], reference["mutations"])
    matched_rows = Enum.count(rows, & &1["matched"])
    matched_mutations = Enum.count(mutations, & &1["matched"])

    complete =
      matched_rows == 12 and matched_mutations == 9 and
        imp["summary"] == reference["summary"] and
        imp["summary"]["positive_passing"] == 12 and
        imp["summary"]["mutations_detected"] == 9

    %{
      "schema_version" => 2,
      "protocol_id" => config["protocol_id"],
      "evidence_level" => config["evidence_level"],
      "source_bindings" => bindings,
      "imp" => Map.take(imp, ["runner", "summary"]),
      "reference" => Map.take(reference, ["runner", "runtime", "summary", "source"]),
      "rows" => rows,
      "mutations" => mutations,
      "summary" => %{
        "positive_rows" => 12,
        "mutation_rows" => 9,
        "matched_positive_rows" => matched_rows,
        "matched_mutation_rows" => matched_mutations,
        "tool_name_accuracy" => imp["summary"]["tool_name_accuracy"],
        "argument_accuracy" => imp["summary"]["argument_accuracy"],
        "terminal_state_accuracy" => imp["summary"]["terminal_state_accuracy"],
        "mutation_detection_accuracy" => imp["summary"]["mutation_detection_accuracy"],
        "fixture_scorer_conformance_complete" => complete,
        "official_bfcl_effectiveness" => false,
        "dspy_comparison" => false,
        "operational_evidence" => false
      },
      "adaptations_and_deviations" => config["adaptations_and_deviations"],
      "limitations" => config["limitations"]
    }
  end

  @doc false
  def validate_artifact!(artifact, opts \\ []) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config, bindings)

    if Keyword.get(opts, :require_clean, true) and
         get_in(artifact, ["run_context", "workspace", "state"]) != "clean" do
      raise ArgumentError, "BFCL-shaped evidence requires a clean source checkout"
    end

    imp = imp_report(config)
    reference = artifact_report(artifact, "reference")
    validate_stored_reference!(reference, imp)
    maybe_replay_reference!(reference, opts)
    expected = pure_expected!(imp, reference)

    unless Enum.sort(Map.keys(artifact)) == @artifact_keys and
             Map.take(artifact, @core_keys) == expected and
             get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["summary"]["fixture_scorer_conformance_complete"] == true and
             artifact["summary"]["official_bfcl_effectiveness"] == false and
             artifact["summary"]["dspy_comparison"] == false and
             artifact["summary"]["operational_evidence"] == false do
      raise ArgumentError,
            "BFCL-shaped artifact rows, summaries, sources, runtime, limitations, or claim flags are invalid"
    end

    artifact
  end

  defp pure_expected!(imp, reference) do
    compare_reports!(imp, reference)
  rescue
    _error in [Mix.Error] ->
      reraise ArgumentError.exception(
                "BFCL-shaped artifact rows, summaries, sources, runtime, limitations, or claim flags are invalid"
              ),
              __STACKTRACE__
  end

  defp validate_stored_reference!(reference, imp) do
    unless reference["rows"] == imp["rows"] and
             reference["mutations"] == imp["mutations"] and
             reference["summary"] == imp["summary"] do
      raise ArgumentError,
            "BFCL-shaped artifact rows, summaries, sources, runtime, limitations, or claim flags are invalid"
    end
  end

  defp maybe_replay_reference!(reference, opts) do
    if Keyword.get(opts, :replay_reference, false) do
      replay =
        opts
        |> Keyword.get(:python, default_python())
        |> validation_reference!()
        |> Map.drop(["schema_version"])

      unless replay == reference do
        raise ArgumentError, "BFCL-shaped Python replay differs from the stored reference report"
      end
    end

    :ok
  end

  defp artifact_report(artifact, side) do
    metadata = artifact[side]

    metadata
    |> Map.put("protocol_id", artifact["protocol_id"])
    |> Map.put("rows", Enum.map(artifact["rows"], & &1[side]))
    |> Map.put("mutations", Enum.map(artifact["mutations"], & &1[side]))
  end

  @doc false
  def source_bindings(config) do
    fixture = config["fixture"]
    upstream = config["upstream_protocol"]

    %{
      "protocol_id" => config["protocol_id"],
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "config_sha256" => file_sha256!(@config_path),
      "fixture_sha256" => file_sha256!(fixture["path"]),
      "upstream_authority_sha256" => file_sha256!(@authority_path),
      "fixture_positive_rows" => fixture["positive_rows"],
      "fixture_mutation_rows" => fixture["mutation_rows"],
      "fixture_license" => fixture["license"],
      "materialization" => fixture["materialization"],
      "upstream_repository" => upstream["repository"],
      "upstream_commit" => upstream["commit"],
      "upstream_usage" => upstream["usage"]
    }
  end

  @doc false
  def score_case!(case), do: score_case!(case, "positive")

  defp score_case!(case, corpus) do
    base = %{"id" => case["id"], "category" => case["category"], "corpus" => corpus}

    with {:ok, expected} <- normalize_trace(case["expected"]),
         {:ok, candidate} <- normalize_trace(case["candidate"]) do
      expected_calls = expected["calls"]
      candidate_calls = candidate["calls"]
      names = Enum.map(candidate_calls, & &1["name"]) == Enum.map(expected_calls, & &1["name"])

      arguments =
        Enum.map(candidate_calls, & &1["arguments"]) ==
          Enum.map(expected_calls, & &1["arguments"])

      terminal = candidate["terminal_state"] == expected["terminal_state"]

      Map.merge(base, %{
        "valid_input" => true,
        "tool_name_exact" => names,
        "arguments_exact" => arguments,
        "terminal_state_exact" => terminal,
        "passing" => names and arguments and terminal,
        "error_code" => nil
      })
    else
      {:error, code} -> Map.merge(base, failed_input(code))
    end
  end

  defp imp_report(config) do
    fixture = read_json!(get_in(config, ["fixture", "path"]))
    rows = Enum.map(fixture["cases"], &score_case!(&1, "positive"))
    mutations = Enum.map(fixture["mutations"], &score_case!(&1, "mutation"))

    %{
      "runner" => "imp-bfcl-shaped-scorer",
      "protocol_id" => config["protocol_id"],
      "rows" => rows,
      "mutations" => mutations,
      "summary" => summarize(rows, mutations, fixture)
    }
  end

  defp normalize_trace(%{"calls" => calls, "terminal_state" => terminal})
       when is_list(calls) and terminal in @terminals do
    try do
      normalized =
        Enum.map(calls, fn
          %{"name" => name, "arguments" => arguments} when is_binary(name) ->
            %{"name" => name, "arguments" => normalize_argument_root!(arguments)}

          _ ->
            throw({:invalid, "invalid_trace"})
        end)

      {:ok, %{"calls" => normalized, "terminal_state" => terminal}}
    catch
      {:invalid, code} -> {:error, code}
    end
  end

  defp normalize_trace(_trace), do: {:error, "invalid_trace"}

  defp normalize_argument_root!(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> normalize_arguments!(decoded)
      {:error, _reason} -> throw({:invalid, "malformed_argument_json"})
    end
  end

  defp normalize_argument_root!(value), do: normalize_arguments!(value)

  defp normalize_arguments!(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), normalize_arguments!(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize_arguments!(value) when is_list(value),
    do: Enum.map(value, &normalize_arguments!/1)

  defp normalize_arguments!(value) when is_binary(value), do: value

  defp normalize_arguments!(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp normalize_arguments!(_value), do: throw({:invalid, "invalid_trace"})

  defp failed_input(code) do
    %{
      "valid_input" => false,
      "tool_name_exact" => false,
      "arguments_exact" => false,
      "terminal_state_exact" => false,
      "passing" => false,
      "error_code" => code
    }
  end

  defp summarize(rows, mutations, fixture) do
    detected =
      Enum.count(mutations, fn row ->
        expected = Enum.find(fixture["mutations"], &(&1["id"] == row["id"]))["expected_score"]
        Map.take(row, @score_keys) == expected
      end)

    %{
      "positive_rows" => length(rows),
      "positive_passing" => Enum.count(rows, & &1["passing"]),
      "mutation_rows" => length(mutations),
      "mutations_detected" => detected,
      "tool_name_accuracy" => Enum.count(rows, & &1["tool_name_exact"]) / length(rows),
      "argument_accuracy" => Enum.count(rows, & &1["arguments_exact"]) / length(rows),
      "terminal_state_accuracy" => Enum.count(rows, & &1["terminal_state_exact"]) / length(rows),
      "mutation_detection_accuracy" => detected / length(mutations)
    }
  end

  defp compare_rows(imp_rows, reference_rows) do
    Enum.zip_with(imp_rows, reference_rows, fn imp_row, reference_row ->
      %{
        "id" => imp_row["id"],
        "matched" => imp_row == reference_row,
        "imp" => imp_row,
        "reference" => reference_row
      }
    end)
  end

  defp assert_exact_ids!(imp_rows, reference_rows, expected_ids, corpus) do
    imp_ids = Enum.map(imp_rows || [], & &1["id"])
    reference_ids = Enum.map(reference_rows || [], & &1["id"])

    unless imp_ids == expected_ids and reference_ids == expected_ids and
             length(expected_ids) == length(Enum.uniq(expected_ids)) do
      Mix.raise("BFCL-shaped reports must contain the exact pinned #{corpus} corpus in order")
    end
  end

  defp fixture_ids(config, key) do
    config
    |> get_in(["fixture", "path"])
    |> read_json!()
    |> Map.fetch!(key)
    |> Enum.map(& &1["id"])
  end

  defp run_reference!(python, out_dir) do
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, "python-bfcl-shaped-#{timestamp_slug()}.json")

    case System.cmd(python, [@script_path, "--out", path], stderr_to_stdout: true) do
      {_output, 0} -> read_json!(path)
      {output, status} -> Mix.raise("Python BFCL-shaped scorer failed #{status}: #{output}")
    end
  end

  defp validate_protocol!(config, bindings) do
    fixture_spec = config["fixture"]
    fixture = read_json!(fixture_spec["path"])
    upstream = config["upstream_protocol"]
    authority = read_json!(@authority_path)
    authority_files = Map.new(authority["source_files"], &{&1["path"], &1["sha256"]})
    actual = String.trim_leading(bindings["fixture_sha256"], "sha256:")

    valid =
      fixture_spec["sha256"] == actual and fixture_spec["positive_rows"] == 12 and
        fixture_spec["mutation_rows"] == 9 and length(fixture["cases"] || []) == 12 and
        length(fixture["mutations"] || []) == 9 and fixture_spec["license"] == "CC0-1.0" and
        get_in(fixture, ["provenance", "row_license"]) == "CC0-1.0" and
        get_in(fixture, ["provenance", "upstream_revision"]) == @bfcl_commit and
        fixture["protocol_id"] == config["protocol_id"] and
        fixture_spec["materialization"] == "checked_in" and
        upstream["repository"] == @bfcl_repository and upstream["commit"] == @bfcl_commit and
        upstream["usage"] == "protocol_provenance_only" and
        upstream["authority_manifest"] == @authority_path and
        authority["repository"] == @bfcl_repository and authority["commit"] == @bfcl_commit and
        authority["license"] == "Apache-2.0" and authority_files == @authority_files and
        Enum.all?(fixture["mutations"], &valid_expected_mutation?/1)

    unless valid,
      do: raise(ArgumentError, "BFCL-shaped fixture, mutation corpus, or provenance is invalid")

    :ok
  end

  defp valid_expected_mutation?(case) do
    Map.keys(case["expected_score"] || %{}) |> Enum.sort() == Enum.sort(@score_keys) and
      case["expected_score"]["passing"] == false
  end

  defp reference_source(bindings) do
    Map.take(bindings, [
      "fixture_sha256",
      "config_sha256",
      "script_sha256",
      "upstream_authority_sha256",
      "upstream_repository",
      "upstream_commit",
      "upstream_usage"
    ])
  end

  defp valid_python_runtime?(
         %{
           "implementation" => implementation,
           "version" => version,
           "dependencies" => "stdlib_only"
         } = runtime
       )
       when is_binary(implementation) and is_binary(version) do
    supported_version =
      case Regex.run(~r/^(\d+)\.(\d+)\.\d+/, version, capture: :all_but_first) do
        [major, minor] -> {String.to_integer(major), String.to_integer(minor)} >= {3, 9}
        _other -> false
      end

    Enum.sort(Map.keys(runtime)) == ~w(dependencies implementation version) and
      implementation == "CPython" and supported_version
  end

  defp valid_python_runtime?(_runtime), do: false

  defp fresh_validation_dir do
    path =
      Path.join(System.tmp_dir!(), "imp-bfcl-validate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp validation_reference!(python) do
    path = fresh_validation_dir()

    try do
      run_reference!(python, path)
    after
      File.rm_rf!(path)
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp file_sha256!(path),
    do: "sha256:" <> (:crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower))

  defp default_python, do: System.find_executable("python3") || "python3"

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
  end
end

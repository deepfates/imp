defmodule Mix.Tasks.Imp.Benchmark.RagToolFailureDifferential do
  @moduledoc """
  Run the provider-free matched Imp/DSPy RAG-tool failure differential.

      mix imp.benchmark.rag_tool_failure_differential \
        --require-clean \
        --out benchmarks/runs/rag-tool-failure-differential

  The preregistered queued LM holds actions constant while actual
  `Imp.Predict.ReAct` and pinned DSPy 3.2.1 `ReAct` execute fixture tools. The
  artifact compares exact normalized observations and terminal states. It does
  not measure model tool selection, retrieval quality, or wall-clock timeout
  implementations.
  """

  use Mix.Task

  @shortdoc "Run the matched provider-free RAG/tool failure differential"
  @config_path "benchmarks/config/rag-tool-failure-differential-v1.json"
  @task_path "lib/mix/tasks/imp.benchmark.rag_tool_failure_differential.ex"
  @script_path "scripts/dspy_rag_tool_failure_differential.py"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"

  @impl true
  def run(args), do: run_with_runners(args, %{})

  @doc false
  def run_with_runners(args, runners) when is_list(args) and is_map(runners) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, python: :string, dspy_source: :string, require_clean: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")

    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config)

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, true),
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@dspy_commit}"},
        inputs: bindings
      )

    out_dir =
      Keyword.get(
        opts,
        :out,
        Imp.BenchmarkTruth.Paths.runs("rag-tool-failure-differential")
      )

    File.mkdir_p!(out_dir)
    imp = run_imp(config, runners[:imp])

    dspy =
      run_dspy(
        Keyword.get(opts, :python, default_python()),
        Keyword.get(opts, :dspy_source, default_dspy_source()),
        out_dir,
        runners[:dspy]
      )

    report = compare!(imp, dspy, config, bindings)
    path = Path.join(out_dir, "rag-tool-failure-differential-#{timestamp_slug()}.json")

    %{artifact: artifact, path: written_path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, report, context)

    Mix.shell().info("RAG/tool failure differential: #{written_path}")

    Mix.shell().info(
      "matched terminal traces: #{artifact["summary"]["matched_rows"]}/#{artifact["summary"]["rows"]}"
    )

    unless artifact["summary"]["provider_free_failure_differential_complete"] do
      Mix.raise("RAG/tool failure differential failed; inspect #{written_path}")
    end
  end

  @doc false
  def validate_artifact!(artifact, opts \\ []) when is_map(artifact) and is_list(opts) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    config = read_json!(@config_path)
    bindings = source_bindings(config)
    validate_protocol!(config)

    if Keyword.get(opts, :require_clean, true) and
         (get_in(artifact, ["run_context", "workspace", "state"]) != "clean" or
            not current_git_clean?()) do
      raise ArgumentError,
            "RAG/tool failure evidence requires a clean source checkout and clean artifact"
    end

    unless get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings and artifact["git_sha"] == current_git_sha!() do
      raise ArgumentError, "RAG/tool failure artifact has stale source bindings"
    end

    imp = side_report(artifact, "imp")
    dspy = side_report(artifact, "dspy")
    expected = compare!(imp, dspy, config, bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected do
      raise ArgumentError, "RAG/tool failure artifact content does not recompute"
    end

    if Keyword.get(opts, :fresh_replay, false),
      do: validate_fresh_replay!(expected, config, bindings)

    artifact
  rescue
    error in [Mix.Error] ->
      reraise ArgumentError.exception(
                "RAG/tool failure artifact content does not recompute: #{error.message}"
              ),
              __STACKTRACE__
  end

  @doc false
  def compare_reports!(imp, dspy) when is_map(imp) and is_map(dspy) do
    config = read_json!(@config_path)
    validate_protocol!(config)
    compare!(imp, dspy, config, source_bindings(config))
  end

  @doc false
  def source_bindings(config) when is_map(config) do
    %{
      "protocol_id" => config["protocol_id"],
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "config_sha256" => file_sha256!(@config_path),
      "authority_sha256" => file_sha256!(@authority_path),
      "dspy_commit" => @dspy_commit,
      "scenario_count" => length(config["scenarios"] || [])
    }
  end

  defp run_imp(config, runner) when is_function(runner, 1), do: runner.(config)
  defp run_imp(config, nil), do: imp_report(config)
  defp run_imp(_config, runner), do: Mix.raise("invalid injected Imp runner: #{inspect(runner)}")

  defp run_dspy(_python, _dspy_source, _out_dir, runner) when is_function(runner, 0),
    do: runner.()

  defp run_dspy(python, dspy_source, out_dir, nil) do
    path = Path.join(out_dir, "dspy-rag-tool-failure-#{timestamp_slug()}.json")
    script = Path.expand(@script_path)
    source = Path.expand(dspy_source)

    case System.cmd(
           python,
           [script, "--dspy-source", source, "--out", Path.expand(path)],
           cd: System.tmp_dir!(),
           env: credential_safe_python_env(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> read_json!(path)
      {output, status} -> Mix.raise("DSPy RAG/tool failure sidecar failed #{status}: #{output}")
    end
  end

  defp run_dspy(_python, _dspy_source, _out_dir, runner),
    do: Mix.raise("invalid injected DSPy runner: #{inspect(runner)}")

  defp imp_report(config) do
    rows = Enum.map(config["scenarios"], &run_imp_scenario/1)

    %{
      "schema_version" => 1,
      "runner" => "imp-rag-tool-failure-differential",
      "protocol_id" => config["protocol_id"],
      "rows" => rows
    }
  end

  defp run_imp_scenario(scenario) do
    {:ok, queue} = Agent.start_link(fn -> imp_responses(scenario) end)
    {:ok, tool_state} = Agent.start_link(fn -> %{unstable: %{}, idempotency: MapSet.new()} end)

    lm = fn _messages, _opts ->
      Agent.get_and_update(queue, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :fixture_response_queue_exhausted}, []}
      end)
    end

    tools = fixture_tools(tool_state)

    program =
      Imp.Predict.ReAct.new("question -> answer", tools,
        lm: lm,
        mode: :dspy_3_2_1,
        max_iters: scenario["max_iters"]
      )
      |> maybe_remove_ghost_tool(scenario["id"])

    try do
      {:ok, prediction} = Imp.call(program, %{question: scenario["id"]})
      history = Map.get(prediction.metadata, :history, [])
      trace = Enum.map(history, &normalize_imp_event/1)

      # DSPy's terminal is `finish` or the step budget: the turn's reason when
      # the model finished, and what interrupted it when it did not.
      reason =
        normalize_terminal_reason(
          prediction.metadata[:termination_cause] || prediction.metadata[:termination_reason]
        )

      answer = prediction |> Imp.Prediction.get(:answer) |> to_string()
      remaining = Agent.get(queue, &length/1)

      %{
        "id" => scenario["id"],
        "trace" => trace,
        "terminal" => classify_terminal(trace, scenario["max_iters"], reason, answer),
        "lm_calls" => length(scenario["actions"]) + 1 - remaining,
        "remaining_responses" => remaining
      }
    after
      Agent.stop(queue)
      Agent.stop(tool_state)
    end
  end

  defp imp_responses(scenario) do
    # :dspy_3_2_1 faithful contract: each turn is the three reasoning fields
    # (next_thought / next_tool_name / next_tool_args), and the reserved
    # terminator is `finish` (no submit alias). The final response is the
    # separate ChainOfThought extraction turn.
    actions =
      Enum.map(scenario["actions"], fn action ->
        %{
          next_thought: "Follow the preregistered schedule.",
          next_tool_name: action["tool"],
          next_tool_args: action["arguments"] || %{}
        }
      end)

    actions ++ [%{reasoning: "Normalize the observed terminal.", answer: scenario["answer"]}]
  end

  defp fixture_tools(state) do
    [
      Imp.tool(:unstable_lookup, "fixture unstable lookup", fn args ->
        key = fetch_arg!(args, "request_id")

        attempt =
          Agent.get_and_update(state, fn data ->
            attempt = Map.get(data.unstable, key, 0) + 1
            {attempt, put_in(data, [:unstable, key], attempt)}
          end)

        if attempt == 1, do: raise("transient_failure"), else: "Paris"
      end),
      Imp.tool(:timed_retriever, "fixture retriever timeout", fn args ->
        "capital-france" = fetch_arg!(args, "query")
        raise "deadline_exceeded"
      end),
      Imp.tool(:idempotent_lookup, "fixture idempotent lookup", fn args ->
        key = fetch_arg!(args, "idempotency_key")

        status =
          Agent.get_and_update(state, fn data ->
            status = if MapSet.member?(data.idempotency, key), do: "replay", else: "fresh"
            {status, %{data | idempotency: MapSet.put(data.idempotency, key)}}
          end)

        %{"status" => status, "value" => "Paris"}
      end),
      Imp.tool(:ghost_lookup, "fixture tool removed after action schema creation", fn args ->
        args
      end),
      Imp.tool(:broken_lookup, "fixture permanent failure", fn args ->
        "capital-france" = fetch_arg!(args, "query")
        raise "permanent_failure"
      end),
      Imp.tool(:stable_lookup, "fixture stable lookup", fn args ->
        "capital-france" = fetch_arg!(args, "query")
        "Paris"
      end)
    ]
  end

  defp maybe_remove_ghost_tool(program, "unknown_tool_then_finish"),
    do: %{program | tools: Map.delete(program.tools, :ghost_lookup)}

  defp maybe_remove_ghost_tool(program, _scenario), do: program

  defp normalize_imp_event(event) do
    tool = normalize_imp_tool(event.tool, event.result)
    arguments = normalize(event.arguments)
    result = event.result
    base = %{"tool" => tool, "arguments" => arguments}

    cond do
      tool == "finish" and result == "Completed." ->
        Map.put(base, "outcome", "terminal")

      tool in ["unstable_lookup", "stable_lookup"] and result == "Paris" ->
        Map.merge(base, %{"outcome" => "success", "value" => "Paris"})

      tool == "idempotent_lookup" and
          result in [
            %{"status" => "fresh", "value" => "Paris"},
            %{"status" => "replay", "value" => "Paris"}
          ] ->
        Map.merge(base, %{"outcome" => result["status"], "value" => result["value"]})

      execution_error?(result, tool, "transient_failure") ->
        Map.put(base, "outcome", "transient_error")

      execution_error?(result, tool, "deadline_exceeded") ->
        Map.put(base, "outcome", "timeout_error")

      execution_error?(result, tool, "permanent_failure") ->
        Map.put(base, "outcome", "permanent_error")

      tool == "ghost_lookup" and is_binary(result) and
        String.starts_with?(result, "Execution error in ghost_lookup:") and
          String.contains?(result, "unknown tool") ->
        Map.put(base, "outcome", "unknown_tool_error")

      true ->
        Map.merge(base, %{
          "outcome" => "unrecognized",
          "observation_sha256" => sha256(Jason.encode!(normalize(result)))
        })
    end
  end

  defp normalize_imp_tool(nil, result) when is_binary(result) do
    if String.starts_with?(result, "Execution error in ghost_lookup:"),
      do: "ghost_lookup",
      else: "unknown"
  end

  defp normalize_imp_tool(tool, _result), do: to_string(tool)

  defp execution_error?(result, tool, marker) do
    is_binary(result) and String.starts_with?(result, "Execution error in #{tool}:") and
      String.contains?(result, marker)
  end

  defp normalize_terminal_reason(:finish), do: "finish"
  defp normalize_terminal_reason(:max_iters), do: "max_iters"
  defp normalize_terminal_reason(reason), do: to_string(reason)

  defp classify_terminal(trace, max_iters, reason, answer) do
    outcomes = Enum.map(trace, & &1["outcome"])

    state =
      cond do
        reason == "max_iters" and length(trace) != max_iters -> "invalid_terminal"
        "transient_error" in outcomes and "success" in outcomes -> "recovered"
        "timeout_error" in outcomes -> "timeout_observed"
        "unknown_tool_error" in outcomes -> "unknown_observed"
        "permanent_error" in outcomes -> "failure_observed"
        "fresh" in outcomes and "replay" in outcomes -> "success"
        reason == "max_iters" -> "budget_exhausted"
        true -> "invalid_terminal"
      end

    %{"reason" => reason, "state" => state, "answer" => answer}
  end

  defp compare!(imp, dspy, config, bindings) do
    validate_side!(imp, "Imp", config)
    validate_dspy_source!(dspy, config, bindings)
    validate_side!(dspy, "DSPy", config)

    rows =
      Enum.zip_with(imp["rows"], dspy["rows"], fn imp_row, dspy_row ->
        matched = imp_row == dspy_row
        %{"id" => imp_row["id"], "matched" => matched, "imp" => imp_row, "dspy" => dspy_row}
      end)

    matched_rows = Enum.count(rows, & &1["matched"])
    count = length(config["scenarios"])
    complete = matched_rows == count

    %{
      "schema_version" => 1,
      "protocol_id" => config["protocol_id"],
      "evidence_level" => "C2_provider_free_operational_failure_differential",
      "admission_requires_clean_source" => true,
      "source_bindings" => bindings,
      "imp" => Map.take(imp, ["runner", "protocol_id", "schema_version"]),
      "dspy" =>
        Map.take(dspy, [
          "runner",
          "protocol_id",
          "schema_version",
          "dspy_version",
          "source",
          "credential_isolation"
        ]),
      "rows" => rows,
      "summary" => %{
        "rows" => count,
        "matched_rows" => matched_rows,
        "provider_free_failure_differential_complete" => complete,
        "model_tool_selection_effectiveness" => false,
        "retrieval_quality_effectiveness" => false,
        "wall_clock_timeout_parity" => false
      },
      "limitations" => config["limitations"]
    }
  end

  defp validate_side!(report, label, config) do
    scenarios = config["scenarios"]
    expected_ids = Enum.map(scenarios, & &1["id"])
    rows = report["rows"] || []

    unless report["protocol_id"] == config["protocol_id"] and
             Enum.map(rows, & &1["id"]) == expected_ids and
             length(rows) == length(Enum.uniq_by(rows, & &1["id"])) do
      Mix.raise("#{label} report must contain the exact preregistered scenario order")
    end

    Enum.zip_with(rows, scenarios, fn row, scenario ->
      expected_calls = length(scenario["actions"]) + 1

      unless row == %{
               "id" => scenario["id"],
               "trace" => scenario["expected_trace"],
               "terminal" => scenario["expected_terminal"],
               "lm_calls" => expected_calls,
               "remaining_responses" => 0
             } do
        Mix.raise("#{label} row #{scenario["id"]} does not recompute from the schedule")
      end
    end)

    :ok
  end

  defp validate_dspy_source!(report, config, bindings) do
    authority = read_json!(@authority_path)
    expected_hashes = Map.new(authority["files"], &{&1["path"], &1["sha256"]})

    expected = %{
      "repository" => "stanfordnlp/dspy",
      "version" => "3.2.1",
      "commit" => @dspy_commit,
      "authority_sha256" => bindings["authority_sha256"],
      "config_sha256" => bindings["config_sha256"],
      "script_sha256" => bindings["script_sha256"],
      "source_materialization" => "clean_git_checkout_of_pinned_tag",
      "git_tag" => "3.2.1",
      "git_clean_before" => true,
      "git_clean_after" => true,
      "authority_manifest_verified_files" => 296,
      "authority_manifest_sha256" => bindings["authority_sha256"],
      "distribution_version" => "3.2.1",
      "module_version" => "3.2.0",
      "imported_from_pinned_checkout" => true
    }

    expected_credentials = %{
      "dummy_canary_present_before_scrub" => true,
      "only_dummy_canary_present_before_scrub" => true,
      "sensitive_values_present_after_scrub" => false,
      "dotenv_disabled" => true,
      "checked_before_import" => true,
      "checked_after_import" => true,
      "checked_during_every_lm_call" => true
    }

    exercised = get_in(config, ["reference", "exercised_sources"])

    unless length(authority["files"]) == 296 and
             Enum.all?(exercised, &is_binary(expected_hashes[&1])) and
             report["dspy_version"] == "3.2.1" and report["source"] == expected and
             report["credential_isolation"] == expected_credentials do
      Mix.raise("DSPy report has unauthenticated or stale exercised source")
    end
  end

  defp validate_protocol!(config) do
    scenarios = config["scenarios"] || []
    ids = Enum.map(scenarios, & &1["id"])
    coverage = MapSet.new(ids)

    unless config["schema_version"] == 1 and
             config["protocol_id"] == "rag-tool-failure-differential-v1" and
             get_in(config, ["reference", "commit"]) == @dspy_commit and
             get_in(config, ["reference", "source_materialization"]) ==
               "clean git checkout at exact 3.2.1 tag and commit" and
             get_in(config, ["reference", "authority_manifest_files"]) == 296 and
             get_in(config, ["execution", "provider_free"]) == true and
             get_in(config, ["credential_isolation", "dotenv"]) == "disabled" and
             length(scenarios) == 6 and length(ids) == length(Enum.uniq(ids)) and
             MapSet.subset?(
               MapSet.new([
                 "transient_retry_then_success",
                 "retriever_timeout_observed",
                 "idempotent_replay",
                 "unknown_tool_then_finish",
                 "failing_tool_then_finish",
                 "iteration_budget_terminal"
               ]),
               coverage
             ) and is_list(config["limitations"]) do
      raise ArgumentError, "RAG/tool failure differential preregistration is invalid"
    end

    Enum.each(scenarios, fn scenario ->
      unless is_integer(scenario["max_iters"]) and scenario["max_iters"] > 0 and
               is_list(scenario["actions"]) and scenario["actions"] != [] and
               is_list(scenario["expected_trace"]) and
               length(scenario["actions"]) == length(scenario["expected_trace"]) and
               is_map(scenario["expected_terminal"]) do
        raise ArgumentError, "invalid preregistered scenario #{inspect(scenario["id"])}"
      end
    end)
  end

  defp validate_fresh_replay!(expected, config, bindings) do
    replay_dir =
      Path.join(
        System.tmp_dir!(),
        "imp-rag-tool-failure-validation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(replay_dir)

    actual =
      try do
        fresh_imp = imp_report(config)
        fresh_dspy = run_dspy(default_python(), default_dspy_source(), replay_dir, nil)
        compare!(fresh_imp, fresh_dspy, config, bindings)
      after
        File.rm_rf!(replay_dir)
      end

    unless actual == expected,
      do: raise(ArgumentError, "RAG/tool failure fresh replay differs from artifact receipt")
  end

  defp side_report(artifact, side) do
    artifact[side]
    |> Map.put("rows", Enum.map(artifact["rows"], & &1[side]))
  end

  defp fetch_arg!(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(args, String.to_atom(key))
    end
  end

  defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> normalize()
  defp normalize(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize(value), do: value

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp sha256(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp file_sha256!(path), do: path |> File.read!() |> sha256()

  defp current_git_sha! do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      {_output, _status} -> raise ArgumentError, "cannot resolve current Imp source revision"
    end
  end

  defp current_git_clean? do
    case System.cmd("git", ["status", "--porcelain=v1"], stderr_to_stdout: true) do
      {"", 0} -> true
      {_output, _status} -> false
    end
  end

  defp credential_safe_python_env do
    scrubbed =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&credential_env_name?/1)
      |> Enum.map(&{&1, nil})

    scrubbed ++
      [
        {"IMP_RAG_FAILURE_DUMMY_API_KEY", "dummy-canary-not-a-credential"},
        {"PYTHON_DOTENV_DISABLED", "1"},
        {"DOTENV_DISABLED", "1"},
        {"PYTHONNOUSERSITE", "1"},
        {"HOME", System.tmp_dir!()}
      ]
  end

  defp credential_env_name?(name) do
    upper = String.upcase(name)

    upper == "PGPASSWORD" or
      Enum.any?(
        ~w(API_KEY ACCESS_KEY AUTH_TOKEN BEARER_TOKEN CLIENT_SECRET CREDENTIAL CREDENTIALS DATABASE_URL PASSWORD PRIVATE_KEY SECRET_KEY TOKEN COOKIE CONNECTION_STRING),
        &(upper == &1 or String.ends_with?(upper, "_" <> &1))
      )
  end

  defp default_python do
    if File.exists?("tmp/dspy-parity-venv/bin/python"),
      do: Path.expand("tmp/dspy-parity-venv/bin/python"),
      else: "python3"
  end

  defp default_dspy_source, do: Path.expand("tmp/dspy-3.2.1")

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
  end
end

defmodule Mix.Tasks.Imp.Benchmark.AvatarOptimizerDifferential do
  @moduledoc "Capture provider-free AvatarOptimizer C1 differential evidence."
  use Mix.Task

  @shortdoc "Capture provider-free AvatarOptimizer C1 evidence"
  @task_path "lib/mix/tasks/imp.benchmark.avatar_optimizer_differential.ex"
  @script_path "scripts/dspy_avatar_optimizer_differential.py"
  @common_path "scripts/dspy_avatar_differential_common.py"
  @config_path "benchmarks/config/avatar-optimizer-differential-v1.json"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @ledger_path "benchmarks/authorities.json"
  @imp_source "lib/imp/optimizer/avatar.ex"
  @dspy_source "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @family_id "family.optimizer_avatar_optimizer"
  @protocol_id "avatar-optimizer-c1-v1"
  @registry_protocol_id "avatar_optimizer_differential"

  @impl true
  def run(args), do: run_capture(args)

  @doc false
  def run_capture(args, runner \\ nil) when is_list(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [out: :string, python: :string, require_clean: :boolean])

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")

    unless Keyword.get(opts, :require_clean, true),
      do: Mix.raise("AvatarOptimizer C1 evidence cannot be captured without --require-clean")

    validate_fixture_authority!()
    bindings = source_bindings()

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: true,
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@dspy_commit}"},
        inputs: bindings
      )

    report =
      if runner, do: runner.(), else: run_python!(Keyword.get(opts, :python, default_python()))

    artifact = build_artifact!(report, bindings)
    out = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("avatar-optimizer-differential"))
    File.mkdir_p!(out)

    name =
      Imp.BenchmarkTruth.ArtifactFile.artifact_name("avatar-optimizer-differential", [
        fixture()["fixture_id"]
      ])

    %{artifact: written, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(Path.join(out, name), artifact, context)

    validate_artifact!(@registry_protocol_id, written)
    Mix.shell().info("AvatarOptimizer provider-free C1 differential artifact: #{path}")
  end

  @doc false
  def build_artifact!(report, bindings \\ nil) when is_map(report) do
    bindings = bindings || source_bindings()
    validate_fixture_authority!()
    validate_report!(report)
    imp = local_observations()
    dspy = report["observations"]

    unless imp == dspy,
      do:
        raise(
          ArgumentError,
          "AvatarOptimizer Imp observations differ from pinned DSPy observations"
        )

    scope = fixture()["scope"]

    %{
      "schema_version" => 1,
      "protocol_id" => @protocol_id,
      "registry_protocol_id" => @registry_protocol_id,
      "family" => "avatar_optimizer",
      "evidence_tier" => "C1",
      "status" => "passing",
      "provider_free" => true,
      "source_bindings" => bindings,
      "scope" => scope,
      "comparison" => %{"dspy" => dspy, "imp" => imp, "matched" => true},
      "dspy_receipt" => report,
      "summary" => %{
        "authenticated_dspy_commit" => @dspy_commit,
        "matched_claim_count" => length(scope["claims"]),
        "upstream_construction_workarounds" => scope["upstream_construction_workarounds"],
        "native_deviations" => scope["native_deviations"],
        "retained_exclusions" => scope["not_claimed"]
      }
    }
  end

  @doc false
  def validate_artifact!(@registry_protocol_id, artifact) when is_map(artifact) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    bindings = source_bindings()

    unless get_in(artifact, ["run_context", "workspace", "state"]) == "clean" and
             committed_sources_match?(artifact["git_sha"], bindings) and
             get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings do
      raise ArgumentError, "AvatarOptimizer C1 artifact is not bound to committed Imp source"
    end

    expected = build_artifact!(artifact["dspy_receipt"], bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected,
      do: raise(ArgumentError, "AvatarOptimizer C1 artifact content does not recompute")

    artifact
  end

  def validate_artifact!(protocol, _artifact),
    do: raise(ArgumentError, "unknown AvatarOptimizer protocol #{inspect(protocol)}")

  @doc false
  def validate_report!(report) do
    config = fixture()

    identity = %{
      "schema_version" => 1,
      "runner" => "python-dspy-avatar-optimizer-differential",
      "fixture_id" => config["fixture_id"],
      "status" => "passing",
      "source" => config["source"],
      "observations" => config["expected"],
      "scope" => config["scope"],
      "isolation" => %{"isolated_process" => true},
      "credential_environment" => %{"provider_credential_names_present" => []}
    }

    required = Map.keys(identity) ++ ["fixture_identity", "runtime_identity"]
    runtime = report["runtime_identity"]

    unless Enum.sort(Map.keys(report)) == Enum.sort(required) and
             Map.take(report, Map.keys(identity)) == identity and
             runtime == expected_runtime() and
             report["fixture_identity"] == %{
               "script_sha256" => raw_file_sha256!(@script_path),
               "common_script_sha256" => raw_file_sha256!(@common_path),
               "config_sha256" => raw_file_sha256!(@config_path)
             } do
      raise ArgumentError, "AvatarOptimizer sidecar receipt or observations are invalid"
    end

    report
  end

  @doc false
  def local_observations do
    config = fixture()
    fixture = config["fixture"]
    {:ok, comparator_count} = Agent.start_link(fn -> 0 end)
    {:ok, rewriter_state} = Agent.start_link(fn -> %{count: 0, feedback: false} end)

    actor_lm =
      static_lm(fn prompt ->
        cond do
          prompt =~ "Do not request another tool." ->
            if prompt =~ "tool_output: \"Paris\"",
              do: %{answer: "Paris"},
              else: %{answer: "unknown"}

          prompt =~ "tool_output:" ->
            finish_action()

          prompt =~ "[[ ## question ## ]]\nhard" and
              prompt =~ fixture["rewritten_instruction"] ->
            %{action: %{tool_name: "lookup", tool_input_query: "France"}}

          prompt =~ "[[ ## question ## ]]\nhard" ->
            %{action: %{tool_name: "lookup", tool_input_query: "wrong"}}

          true ->
            %{action: %{tool_name: "lookup", tool_input_query: "France"}}
        end
      end)

    lookup =
      Imp.tool(:lookup, "Look up a capital", fn country ->
        if country == "France", do: "Paris", else: "unknown"
      end)

    student =
      Imp.avatar("question -> answer", [lookup], lm: actor_lm, max_iters: 2)
      |> Imp.Predict.Avatar.put_instruction(fixture["initial_instruction"])

    trainset = [
      Imp.example(question: "easy", answer: "Paris") |> Imp.with_inputs(:question),
      Imp.example(question: "hard", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    comparator_lm =
      static_lm(fn _prompt ->
        Agent.update(comparator_count, &(&1 + 1))
        %{feedback: fixture["feedback"]}
      end)

    rewrite_lm =
      static_lm(fn prompt ->
        Agent.update(rewriter_state, fn state ->
          %{count: state.count + 1, feedback: prompt =~ fixture["feedback"]}
        end)

        %{new_instruction: fixture["rewritten_instruction"]}
      end)

    compiled =
      Imp.Optimizer.Avatar.new(Imp.exact_match(:answer),
        max_iters: 1,
        lower_bound: fixture["lower_bound"],
        upper_bound: fixture["upper_bound"],
        max_positive_inputs: 1,
        max_negative_inputs: 1,
        comparator_lm: comparator_lm,
        rewrite_lm: rewrite_lm
      )
      |> Imp.Optimizer.Avatar.compile(student, trainset)

    report = Imp.Optimizer.Report.fetch(compiled)
    [round] = report.metadata.rounds
    rewrite = Agent.get(rewriter_state, & &1)

    result = %{
      "positive_count" => round.positive_count,
      "negative_count" => round.negative_count,
      "comparator_call_count" => Agent.get(comparator_count, & &1),
      "rewriter_call_count" => rewrite.count,
      "feedback_propagated" => rewrite.feedback and round.feedback == fixture["feedback"],
      "final_instruction" => Imp.Predict.Avatar.current_instruction(compiled)
    }

    Agent.stop(comparator_count)
    Agent.stop(rewriter_state)
    result
  end

  @doc false
  def source_bindings do
    %{
      "protocol_id" => @protocol_id,
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "common_script_sha256" => file_sha256!(@common_path),
      "config_sha256" => file_sha256!(@config_path),
      "authority_manifest_sha256" => file_sha256!(@authority_path),
      "authority_family_sha256" => family_sha256!(File.read!(@ledger_path)),
      "imp_source_sha256" => file_sha256!(@imp_source),
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
    case System.cmd(python, [Path.expand(@script_path), "--config", Path.expand(@config_path)],
           cd: File.cwd!(),
           env: credential_safe_python_env(),
           stderr_to_stdout: false
         ) do
      {output, 0} -> Jason.decode!(output)
      {output, status} -> Mix.raise("AvatarOptimizer sidecar failed #{status}: #{output}")
    end
  end

  defp validate_fixture_authority! do
    config = fixture()
    source = config["source"]
    manifest = read_json!(@authority_path)

    family =
      read_json!(@ledger_path)["families"] |> Enum.find(&(&1["id"] == source["authority_family"]))

    canonical = family && family["upstream_repository"]
    fields = ~w(repository version git_ref commit source_manifest)
    files = Map.new(manifest["files"], &{&1["path"], &1["sha256"]})

    unless is_map(canonical) and Map.take(source, fields) == Map.take(canonical, fields) and
             source["commit"] == @dspy_commit and manifest["commit"] == @dspy_commit and
             source["source_manifest"]["sha256"] == raw_file_sha256!(@authority_path) and
             Enum.all?(source["source_files"], fn entry ->
               files[entry["path"]] == entry["sha256"] and
                 entry["sha256"] in family["upstream_source_hashes"]
             end) do
      raise ArgumentError, "AvatarOptimizer fixture is not bound to canonical DSPy authority"
    end
  end

  defp expected_runtime do
    source = fixture()["source"]

    %{
      "authority_family_sha256" =>
        @ledger_path |> File.read!() |> family_sha256!() |> String.replace_prefix("sha256:", ""),
      "authority_manifest_sha256" => raw_file_sha256!(@authority_path),
      "authority_manifest_verified_files" => source["source_manifest"]["file_count"],
      "distribution_version" => source["version"],
      "module_version" => "3.2.0",
      "git_clean" => true,
      "git_commit" => @dspy_commit,
      "git_tag" => source["version"],
      "source_root" => @dspy_source
    }
  end

  defp committed_sources_match?(git_sha, bindings) when is_binary(git_sha) do
    files = [
      {@task_path, "task_sha256"},
      {@script_path, "script_sha256"},
      {@common_path, "common_script_sha256"},
      {@config_path, "config_sha256"},
      {@authority_path, "authority_manifest_sha256"},
      {@imp_source, "imp_source_sha256"}
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

  defp static_lm(handler) do
    Imp.LM.Static.new(
      handler: fn messages, _opts -> handler.(Enum.map_join(messages, "\n", & &1.content)) end
    )
  end

  defp credential_env_name?(name) do
    upper = String.upcase(name)

    upper == "PGPASSWORD" or
      Enum.any?(
        ~w(API_KEY ACCESS_KEY ACCESS_TOKEN AUTHORIZATION AUTH_TOKEN BEARER_TOKEN CLIENT_SECRET CREDENTIAL CREDENTIALS DATABASE_URL PASSWORD PRIVATE_KEY SECRET SECRET_KEY TOKEN COOKIE CONNECTION_STRING),
        &(upper == &1 or String.ends_with?(upper, "_" <> &1))
      )
  end

  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}
  defp fixture, do: read_json!(@config_path)
  defp default_python, do: Path.expand("tmp/dspy-parity-venv/bin/python")
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp file_sha256!(path), do: "sha256:" <> raw_file_sha256!(path)
  defp raw_file_sha256!(path), do: path |> File.read!() |> raw_sha256()
  defp raw_sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

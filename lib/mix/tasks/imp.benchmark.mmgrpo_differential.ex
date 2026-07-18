defmodule Mix.Tasks.Imp.Benchmark.MmgrpoDifferential do
  @moduledoc "Capture provider-free mmGRPO C1 semantic differential evidence."

  use Mix.Task

  @shortdoc "Capture provider-free mmGRPO C1 evidence"
  @protocol_id "mmgrpo-c1-v1"
  @registry_protocol_id "mmgrpo_differential"
  @family_id "family.optimizer_mmgrpo"
  @task_path "lib/mix/tasks/imp.benchmark.mmgrpo_differential.ex"
  @script_path "scripts/dspy_mmgrpo_differential.py"
  @config_path "benchmarks/config/mmgrpo-differential-v1.json"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @ledger_path "benchmarks/authorities.json"
  @imp_source_path "lib/imp/optimizer/grpo.ex"
  @dspy_source "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"

  defmodule FixtureTrainer do
    @moduledoc false
    @behaviour Imp.Clients.Trainer
    defstruct [:owner]

    @impl true
    def supported_methods(_trainer), do: [:grpo]

    @impl true
    def start_reinforcement(trainer, lm, _opts) do
      {:ok,
       Imp.Clients.ReinforcementSession.new(%{
         id: "provider-free-mmgrpo",
         provider: :fixture,
         model: lm,
         pending_batch_ids: [1, 2],
         backend_state: %{owner: trainer.owner}
       })}
    end

    @impl true
    def reinforcement_status(_trainer, session) do
      offset = length(session.fulfilled_batch_ids)
      {:ok, %{session | pending_batch_ids: [offset + 1, offset + 2]}}
    end

    @impl true
    def reinforcement_step(_trainer, session, groups, _opts) do
      send(session.backend_state.owner, {:mmgrpo_fixture_step, groups})
      {:ok, session}
    end

    @impl true
    def terminate_reinforcement(_trainer, session),
      do: {:ok, %{session | status: :succeeded, pending_batch_ids: []}}

    @impl true
    def final_model_artifact(_trainer, _session), do: {:ok, "fixture/mmgrpo-trained"}
  end

  defmodule FixtureTwoPredictorProgram do
    @moduledoc false
    @behaviour Imp.Module
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    @impl true
    def call(program, inputs) do
      with {:ok, first} <- Imp.Module.call(program.first, inputs),
           {:ok, second} <- Imp.Module.call(program.second, inputs) do
        {:ok,
         Imp.Prediction.new(
           Map.merge(Imp.Prediction.to_map(first), Imp.Prediction.to_map(second))
         )}
      end
    end
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
      Mix.raise("mmGRPO C1 evidence cannot be captured without --require-clean")
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
    out = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("mmgrpo-differential"))
    File.mkdir_p!(out)

    name =
      Imp.BenchmarkTruth.ArtifactFile.artifact_name(
        "mmgrpo-differential",
        [fixture()["fixture_id"]]
      )

    %{artifact: written, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(Path.join(out, name), artifact, context)

    validate_artifact!(@registry_protocol_id, written)
    Mix.shell().info("mmGRPO provider-free C1 differential artifact: #{path}")
  end

  @doc false
  def build_artifact!(report, bindings \\ source_bindings()) when is_map(report) do
    validate_fixture_authority!()
    validate_report!(report)
    local = local_observations()
    upstream = report["observations"]

    unless local == upstream do
      raise ArgumentError, "Imp mmGRPO observations differ from pinned DSPy observations"
    end

    %{
      "schema_version" => 1,
      "protocol_id" => @protocol_id,
      "registry_protocol_id" => @registry_protocol_id,
      "family" => "mmgrpo",
      "evidence_tier" => "C1",
      "status" => "passing",
      "provider_free" => true,
      "source_bindings" => bindings,
      "scope" => fixture()["scope"],
      "comparison" => %{"dspy" => upstream, "imp" => local, "matched" => true},
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
      raise ArgumentError, "mmGRPO C1 admission requires a clean checkout"
    end

    unless committed_sources_match?(artifact["git_sha"], bindings) and
             get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings do
      raise ArgumentError, "mmGRPO C1 artifact is not bound to committed Imp source"
    end

    expected = build_artifact!(artifact["dspy_receipt"], bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected do
      raise ArgumentError, "mmGRPO C1 artifact content does not recompute"
    end

    artifact
  end

  def validate_artifact!(protocol_id, _artifact),
    do: raise(ArgumentError, "unknown mmGRPO protocol #{inspect(protocol_id)}")

  @doc false
  def local_observations do
    config = fixture()["fixture"]
    success_batches = run_success_fixture(config)
    predictor_names = run_predictor_fixture(config)
    failed_group = run_format_failure_fixture(config)

    ids = Enum.map(success_batches, &question_from_batch!/1)
    group_sizes = Enum.map(success_batches, &length(&1.group)) |> Enum.uniq()

    %{
      "selected_id_counts" => ids |> Enum.frequencies() |> stringify_keys(),
      "selected_example_count" => length(ids),
      "successful_group_count" => length(success_batches),
      "successful_group_size" => singleton!(group_sizes),
      "successful_rewards" =>
        success_batches
        |> Enum.flat_map(& &1.group)
        |> Enum.map(& &1.reward)
        |> Enum.uniq()
        |> Enum.sort(),
      "predictor_group_names" => predictor_names,
      "format_failure_group_size" => length(failed_group),
      "format_failure_rewards" =>
        failed_group |> Enum.map(& &1.reward) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp run_success_fixture(config) do
    handler = fn messages, opts ->
      id = question_from_messages!(messages)
      %{answer: "#{id}-#{Keyword.fetch!(opts, :rollout_id)}"}
    end

    run_imp_fixture(
      handler,
      config["success_reward"],
      config["train_ids"],
      num_train_steps: config["num_train_steps"],
      num_dspy_examples_per_grpo_step: config["examples_per_step"],
      num_rollouts_per_grpo_step: config["rollouts_per_step"]
    )
  end

  defp run_format_failure_fixture(config) do
    [batch | _] =
      run_imp_fixture(
        fn _messages, _opts -> %{} end,
        config["success_reward"],
        ["failed"],
        num_train_steps: 1,
        num_dspy_examples_per_grpo_step: 1,
        num_rollouts_per_grpo_step: config["rollouts_per_step"],
        format_failure_score: config["format_failure_reward"]
      )

    batch.group
  end

  defp run_predictor_fixture(config) do
    lm = %{
      module: Imp.LM.Static,
      model: "provider-free-fixture",
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))
          if String.contains?(prompt, "first"), do: %{first: "one"}, else: %{second: "two"}
        end
      ]
    }

    program = %FixtureTwoPredictorProgram{
      first: Imp.predict("question -> first", lm: lm),
      second: Imp.predict("question -> second", lm: lm)
    }

    run_imp_program_fixture(
      program,
      config["success_reward"],
      ["attribution"],
      num_train_steps: 1,
      num_dspy_examples_per_grpo_step: 1,
      num_rollouts_per_grpo_step: config["rollouts_per_step"]
    )
    |> Enum.map(&to_string(&1.predictor))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp run_imp_fixture(handler, reward, ids, opts) do
    lm = %{module: Imp.LM.Static, opts: [handler: handler], model: "provider-free-fixture"}
    program = Imp.predict("question -> answer", lm: lm)
    run_imp_program_fixture(program, reward, ids, opts)
  end

  defp run_imp_program_fixture(program, reward, ids, opts) do
    trainer = %FixtureTrainer{owner: self()}

    optimizer =
      Imp.Optimizer.GRPO.new(
        fn _example, _prediction -> reward end,
        Keyword.merge(
          [trainer: trainer, seed: 0, status_poll_interval_ms: 0],
          opts
        )
      )

    trainset = Enum.map(ids, &(Imp.example(question: &1) |> Imp.with_inputs(:question)))
    {:ok, _compiled} = Imp.Optimizer.GRPO.compile(optimizer, program, trainset)
    collect_batches([])
  end

  defp collect_batches(acc) do
    receive do
      {:mmgrpo_fixture_step, batches} -> collect_batches(acc ++ batches)
    after
      0 -> acc
    end
  end

  defp question_from_batch!(batch), do: question_from_messages!(hd(batch.group).messages)

  defp question_from_messages!(messages) do
    content =
      messages
      |> Enum.find(&(to_string(Map.get(&1, :role)) == "user"))
      |> Map.fetch!(:content)

    Enum.find(fixture()["fixture"]["train_ids"] ++ ["failed"], &String.contains?(content, &1)) ||
      raise ArgumentError, "fixture question absent from GRPO messages"
  end

  defp singleton!([value]), do: value
  defp singleton!(values), do: raise(ArgumentError, "expected one value, got #{inspect(values)}")
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

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
             "observations" => fixture()["fixture"]["expected"]
           } do
      raise ArgumentError, "mmGRPO sidecar receipt is invalid"
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
      raise ArgumentError, "mmGRPO fixture is not bound to canonical DSPy authority"
    end

    manifest_files = Map.new(manifest["files"], &{&1["path"], &1["sha256"]})
    grpo_source = source["grpo_source"]

    unless manifest_files[grpo_source["path"]] == grpo_source["sha256"] do
      raise ArgumentError, "mmGRPO source is absent from the DSPy authority manifest"
    end

    test = source["upstream_test"]
    references = get_in(family, ["upstream_tests", "references"]) || []

    unless "#{test["path"]}#sha256=#{test["sha256"]}" in references do
      raise ArgumentError, "mmGRPO upstream test is absent from the authority ledger"
    end

    Enum.each([grpo_source, test], fn entry ->
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
      {output, status} -> Mix.raise("mmGRPO sidecar failed #{status}: #{output}")
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

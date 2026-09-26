defmodule Mix.Tasks.Imp.Benchmark.WeightCompositionDifferential do
  @moduledoc false

  alias Imp.Clients.TrainingJob
  alias Imp.Optimizer.{BetterTogether, BootstrapFinetune, Report}

  @task_path "lib/mix/tasks/imp.benchmark.weight_composition_differential.ex"
  @script_path "scripts/dspy_weight_composition_differential.py"
  @config_path "benchmarks/config/weight-composition-differential-v1.json"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @ledger_path "benchmarks/authorities.json"
  @dspy_source "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @families %{
    "bootstrap_finetune" => %{
      protocol_id: "bootstrap-finetune-c1-v1",
      source_path: "lib/imp/optimizer/bootstrap_finetune.ex"
    },
    "better_together" => %{
      protocol_id: "better-together-c1-v1",
      source_path: "lib/imp/optimizer/better_together.ex"
    }
  }

  defmodule TwoPredictorProgram do
    @moduledoc false
    @behaviour Imp.Module
    defstruct [:first, :second, metadata: %{}]

    @impl true
    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    @impl true
    def update_optimizer_predictor(program, name, update), do: Map.update!(program, name, update)

    @impl true
    def call(program, inputs) do
      with {:ok, first} <- Imp.Module.call(program.first, inputs),
           {:ok, second} <- Imp.Module.call(program.second, inputs) do
        {:ok,
         first
         |> Imp.Prediction.to_map()
         |> Map.merge(Imp.Prediction.to_map(second))
         |> Imp.Prediction.new()}
      end
    end
  end

  defmodule PromptToggle do
    @moduledoc false
    @behaviour Imp.Optimizer
    defstruct []
    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{}, program, _opts) do
      next =
        if Imp.Optimizer.InstructionSearch.current_instruction(program) ==
             "Answer every question.",
           do: "Answer neither question.",
           else: "Answer every question."

      {:ok, Imp.Optimizer.InstructionSearch.put_instruction(program, next)}
    end
  end

  defmodule IdentityOptimizer do
    @moduledoc false
    @behaviour Imp.Optimizer
    defstruct []
    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{}, program, _opts), do: {:ok, program}
  end

  def run_family(family, args, runner \\ nil) do
    family_config!(family)

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [out: :string, python: :string, require_clean: :boolean])

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")

    unless Keyword.get(opts, :require_clean, true),
      do: Mix.raise("#{family} C1 evidence cannot be captured without --require-clean")

    Mix.Task.run("app.start")
    bindings = source_bindings(family)
    validate_fixture_authority!()

    context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: true,
        source_commits: %{"dspy" => "stanfordnlp/dspy@#{@dspy_commit}"},
        inputs: bindings
      )

    report =
      if runner, do: runner.(), else: run_python!(Keyword.get(opts, :python, default_python()))

    artifact = build_artifact!(family, report, bindings)
    out = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs(String.replace(family, "_", "-")))
    File.mkdir_p!(out)

    name =
      Imp.BenchmarkTruth.ArtifactFile.artifact_name(String.replace(family, "_", "-"), [
        fixture()["fixture_id"]
      ])

    %{artifact: written, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(Path.join(out, name), artifact, context)

    validate_artifact!(family, written)
    Mix.shell().info("#{family} provider-free C1 differential artifact: #{path}")
  end

  @doc false
  def build_artifact!(family, report, bindings \\ nil) do
    config = family_config!(family)
    bindings = bindings || source_bindings(family)
    validate_fixture_authority!()
    validate_report!(report)
    dspy = get_in(report, ["observations", family])
    imp = local_observations(family)
    shared_match = dspy["shared"] == imp["shared"]

    unless shared_match,
      do: raise(ArgumentError, "#{family} shared observations differ from pinned DSPy")

    deviation =
      case family do
        "bootstrap_finetune" ->
          %{
            "dspy" => dspy["dspy_deviation"],
            "imp_native" => imp["imp_native"],
            "classification" => "intentional_corrective_deviation"
          }

        "better_together" ->
          %{
            "imp_native" => imp["imp_native"],
            "classification" => "bounded_beam_native_extension"
          }
      end

    scope = get_in(fixture(), ["scopes", family])

    %{
      "schema_version" => 1,
      "protocol_id" => config.protocol_id,
      "family" => family,
      "evidence_tier" => "C1",
      "status" => "passing",
      "provider_free" => true,
      "source_bindings" => bindings,
      "scope" => scope,
      "comparison" => %{
        "dspy" => dspy,
        "imp" => imp,
        "shared_matched" => true,
        "deviation" => deviation
      },
      "dspy_receipt" => report,
      "summary" => %{
        "authenticated_dspy_commit" => @dspy_commit,
        "matched_claim_count" => length(scope["claims"]),
        "retained_exclusions" => scope["not_claimed"]
      }
    }
  end

  @doc false
  def validate_artifact!(family, artifact) when is_binary(family) and is_map(artifact) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    bindings = source_bindings(family)

    unless get_in(artifact, ["run_context", "workspace", "state"]) == "clean" do
      raise ArgumentError, "#{family} C1 admission requires a clean checkout"
    end

    unless committed_sources_match?(artifact["git_sha"], family, bindings) and
             get_in(artifact, ["run_context", "inputs"]) == bindings and
             artifact["source_bindings"] == bindings do
      raise ArgumentError, "#{family} C1 artifact is not bound to committed Imp source"
    end

    expected = build_artifact!(family, artifact["dspy_receipt"], bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected do
      raise ArgumentError, "#{family} C1 artifact content does not recompute"
    end

    artifact
  end

  @doc false
  def validate_report!(report) do
    expected = fixture()

    required =
      ~w(credential_environment fixture_id fixture_identity isolation observations provider_free runner runtime_identity schema_version scopes source status)

    expected_observations = %{
      "bootstrap_finetune" => %{
        "shared" => expected["bootstrap_finetune"]["expected_shared"],
        "dspy_deviation" => expected["bootstrap_finetune"]["expected_dspy_deviation"]
      },
      "better_together" => %{"shared" => expected["better_together"]["expected_shared"]}
    }

    valid =
      Enum.sort(Map.keys(report)) == Enum.sort(required) and
        report["schema_version"] == 1 and
        report["runner"] == "python-dspy-weight-composition-differential" and
        report["fixture_id"] == expected["fixture_id"] and report["status"] == "passing" and
        report["provider_free"] == true and report["source"] == expected["source"] and
        report["scopes"] == expected["scopes"] and
        report["isolation"] == %{"isolated_process" => true} and
        report["credential_environment"] == %{"provider_credential_names_present" => []} and
        report["observations"] == expected_observations and
        valid_runtime?(report["runtime_identity"], expected["source"]) and
        report["fixture_identity"] == %{
          "script_sha256" => raw_file_sha256!(@script_path),
          "config_sha256" => raw_file_sha256!(@config_path)
        }

    unless valid,
      do: raise(ArgumentError, "weight composition sidecar receipt or observations are invalid")

    report
  end

  @doc false
  def local_observations("bootstrap_finetune") do
    shared_lm =
      Imp.LM.Static.new(
        model: "fixture",
        handler: fn _messages, _opts -> %{first_answer: "one", second_answer: "two"} end
      )

    program = %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: shared_lm),
      second: Imp.predict("question -> second_answer", lm: shared_lm)
    }

    example = Imp.example(question: "q") |> Imp.with_inputs(:question)

    trainer = fn _lm, _examples, _opts ->
      {:ok, TrainingJob.new(%{id: "provider-free-fixture", status: :created})}
    end

    metric = fn _example, _prediction -> 1.0 end
    multitask_optimizer = BootstrapFinetune.new(metric, trainer: trainer, multitask: true)
    per_predictor_optimizer = BootstrapFinetune.new(metric, trainer: trainer, multitask: false)
    multitask = BootstrapFinetune.compile(multitask_optimizer, program, [example])
    per_predictor = BootstrapFinetune.compile(per_predictor_optimizer, program, [example])
    [first, second] = per_predictor.plan.entries
    tags = fn entry -> Enum.map(entry.rows, &Atom.to_string(&1.predictor_name)) end

    %{
      "shared" => %{
        "multitask_job_count" => length(multitask.plan.entries),
        "per_predictor_job_count" => length(per_predictor.plan.entries),
        "trace_call_members" => multitask.plan.entries |> Enum.flat_map(tags) |> Enum.sort()
      },
      "imp_native" => %{
        "requested_predictor_0_rows" => tags.(first),
        "requested_predictor_1_rows" => tags.(second),
        "launch_timeout_ms" => per_predictor_optimizer.launch_timeout,
        "cancellation_timeout_ms" => per_predictor_optimizer.cancellation_timeout
      }
    }
  end

  def local_observations("better_together") do
    rows = [example("France", "Paris"), example("Germany", "Berlin")]

    optimizer =
      BetterTogether.new(Imp.Metrics.exact_match(:answer), %{
        p: %PromptToggle{},
        w: %IdentityOptimizer{}
      })

    validated =
      BetterTogether.compile(optimizer, fixture_program(), rows, rows,
        strategy: "p -> w -> p",
        shuffle_trainset_between_steps: false
      )

    unvalidated =
      BetterTogether.compile(optimizer, fixture_program(), rows, nil,
        strategy: "p -> w -> p",
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    report = Report.fetch(validated)
    latest = Report.fetch(unvalidated)

    %{
      "shared" => %{
        "steps" => Enum.map(report.metadata.steps, &to_string/1),
        "candidate_prefixes" => Enum.map(report.candidates, & &1.strategy),
        "selected_with_validation" => report.metadata.selected_strategy,
        "selected_without_validation" => latest.metadata.selected_strategy,
        "earlier_tie_wins" => report.metadata.selected_strategy == "p"
      },
      "imp_native" => %{
        "training_launch_timeout_ms" => report.metadata.training_launch_timeout,
        "training_timeout_ms" => report.metadata.training_timeout,
        "training_poll_interval_ms" => report.metadata.training_poll_interval,
        "training_cancellation_timeout_ms" => report.metadata.training_cancellation_timeout
      }
    }
  end

  @doc false
  def source_bindings(family) do
    config = family_config!(family)

    %{
      "protocol_id" => config.protocol_id,
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "config_sha256" => file_sha256!(@config_path),
      "authority_manifest_sha256" => file_sha256!(@authority_path),
      "authority_family_sha256" => authority_family_sha256!(family),
      "imp_optimizer_source_sha256" => file_sha256!(config.source_path),
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

  defp fixture_program do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)

            answer =
              cond do
                prompt =~ "Answer every question." and prompt =~ "Germany" -> "Berlin"
                prompt =~ "Answer every question." -> "Paris"
                true -> "unknown"
              end

            %{answer: answer}
          end
        )
    )
  end

  defp example(question, answer),
    do: Imp.example(question: question, answer: answer) |> Imp.with_inputs(:question)

  defp run_python!(python) do
    case System.cmd(python, [Path.expand(@script_path), "--config", Path.expand(@config_path)],
           cd: File.cwd!(),
           env: credential_safe_python_env(),
           stderr_to_stdout: false
         ) do
      {output, 0} -> Jason.decode!(output)
      {output, status} -> Mix.raise("weight composition sidecar failed #{status}: #{output}")
    end
  end

  defp validate_fixture_authority! do
    source = fixture()["source"]
    manifest = read_json!(@authority_path)
    ledger = read_json!(@ledger_path)
    files = Map.new(manifest["files"], &{&1["path"], &1["sha256"]})
    canonical = ~w(repository version git_ref commit source_manifest)

    valid =
      source["commit"] == @dspy_commit and manifest["commit"] == @dspy_commit and
        source["source_manifest"]["sha256"] == raw_file_sha256!(@authority_path) and
        source["source_manifest"]["file_count"] == length(manifest["files"])

    valid =
      Enum.reduce(source["families"], valid, fn {_name, family}, acc ->
        authority = Enum.find(ledger["families"], &(&1["id"] == family["authority_family"]))

        reference =
          "#{family["upstream_test"]["path"]}#sha256=#{family["upstream_test"]["sha256"]}"

        ((acc and authority) &&
           Map.take(source, canonical) == Map.take(authority["upstream_repository"], canonical)) and
          files[family["source"]["path"]] == family["source"]["sha256"] and
          reference in authority["upstream_tests"]["references"]
      end)

    unless valid,
      do:
        raise(
          ArgumentError,
          "weight composition fixture is not bound to canonical DSPy authority"
        )
  end

  defp valid_runtime?(runtime, source) do
    runtime == %{
      "authority_family_sha256" =>
        Map.new(source["families"], fn {family, _source} ->
          {family, String.replace_prefix(authority_family_sha256!(family), "sha256:", "")}
        end),
      "authority_manifest_sha256" => raw_file_sha256!(@authority_path),
      "authority_manifest_verified_files" => source["source_manifest"]["file_count"],
      "distribution_version" => source["version"],
      "git_clean" => true,
      "git_commit" => @dspy_commit,
      "git_tag" => source["version"],
      "module_version" => "3.2.0",
      "source_root" => @dspy_source
    }
  end

  defp committed_sources_match?(git_sha, family, bindings) when is_binary(git_sha) do
    config = family_config!(family)

    files = [
      {@task_path, "task_sha256"},
      {@script_path, "script_sha256"},
      {@config_path, "config_sha256"},
      {@authority_path, "authority_manifest_sha256"},
      {config.source_path, "imp_optimizer_source_sha256"}
    ]

    family_matches =
      case System.cmd("git", ["show", "#{git_sha}:#{@ledger_path}"], stderr_to_stdout: true) do
        {bytes, 0} ->
          authority_family_sha256!(family, bytes) == bindings["authority_family_sha256"]

        _ ->
          false
      end

    Regex.match?(~r/^[0-9a-f]{40}$/, git_sha) and family_matches and
      Enum.all?(files, fn {path, key} ->
        case System.cmd("git", ["show", "#{git_sha}:#{path}"], stderr_to_stdout: true) do
          {bytes, 0} -> "sha256:" <> raw_sha256(bytes) == bindings[key]
          _ -> false
        end
      end)
  end

  defp committed_sources_match?(_, _, _), do: false

  defp family_config!(family),
    do:
      Map.get(@families, family) ||
        raise(ArgumentError, "unknown weight composition family #{inspect(family)}")

  defp authority_family_sha256!(family, ledger_bytes \\ File.read!(@ledger_path)) do
    authority_family = get_in(fixture(), ["source", "families", family, "authority_family"])
    ledger = Jason.decode!(ledger_bytes)
    entry = Enum.find(ledger["families"], &(&1["id"] == authority_family))
    unless entry, do: raise(ArgumentError, "missing #{authority_family} authority")
    "sha256:" <> raw_sha256(Imp.Training.ChatDataset.canonical_json(entry))
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

defmodule Mix.Tasks.Imp.Benchmark.BootstrapFinetuneDifferential do
  @moduledoc "Capture provider-free BootstrapFinetune C1 differential evidence."
  use Mix.Task
  @shortdoc "Capture provider-free BootstrapFinetune C1 evidence"
  @impl true
  def run(args),
    do:
      Mix.Tasks.Imp.Benchmark.WeightCompositionDifferential.run_family("bootstrap_finetune", args)
end

defmodule Mix.Tasks.Imp.Benchmark.BetterTogetherDifferential do
  @moduledoc "Capture provider-free BetterTogether C1 differential evidence."
  use Mix.Task
  @shortdoc "Capture provider-free BetterTogether C1 evidence"
  @impl true
  def run(args),
    do: Mix.Tasks.Imp.Benchmark.WeightCompositionDifferential.run_family("better_together", args)
end

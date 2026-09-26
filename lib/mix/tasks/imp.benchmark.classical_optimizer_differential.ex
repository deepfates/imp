defmodule Mix.Tasks.Imp.Benchmark.ClassicalOptimizerDifferential do
  @moduledoc false

  alias Imp.Optimizer.{BootstrapFewShotWithRandomSearch, Report}

  @task_path "lib/mix/tasks/imp.benchmark.classical_optimizer_differential.ex"
  @script_path "scripts/dspy_classical_optimizer_differential.py"
  @config_path "benchmarks/config/classical-optimizer-differential-v1.json"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @ledger_path "benchmarks/authorities.json"
  @dspy_source "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @families %{
    "bootstrap_few_shot" => %{
      protocol_id: "bootstrap-few-shot-c1-v1",
      registry_id: "bootstrap_few_shot_differential",
      source_path: "lib/imp/optimizer/bootstrap_few_shot.ex"
    },
    "random_search" => %{
      protocol_id: "random-search-c1-v1",
      registry_id: "random_search_differential",
      source_path: "lib/imp/optimizer/random_search.ex"
    }
  }

  defmodule FixtureProgram do
    @moduledoc false
    defstruct [:main, :answers]

    def optimizer_predictors(program), do: [main: program.main]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | main: update.(program.main)}

    def call(program, %{question: question}) do
      answer = Map.fetch!(program.answers, question)

      trace = [
        %{predictor: :main, inputs: %{question: question}, outputs: %{answer: answer}}
      ]

      {:ok, Imp.Prediction.new(%{answer: answer}, metadata: %{optimizer_trace: trace})}
    end
  end

  def run_family(family, args, runner \\ nil)
      when is_binary(family) and is_list(args) and (is_nil(runner) or is_function(runner, 0)) do
    family_config!(family)

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, python: :string, require_clean: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(rest ++ invalid)}")
    Mix.Task.run("app.start")

    unless Keyword.get(opts, :require_clean, true) do
      Mix.raise("#{family} C1 evidence cannot be captured without --require-clean")
    end

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
    out = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs(family_slug(family)))
    File.mkdir_p!(out)

    name =
      Imp.BenchmarkTruth.ArtifactFile.artifact_name(family_slug(family), [fixture()["fixture_id"]])

    %{artifact: written, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(Path.join(out, name), artifact, context)

    validate_artifact!(family_config!(family).registry_id, written)
    Mix.shell().info("#{family} provider-free C1 differential artifact: #{path}")
  end

  @doc false
  def build_artifact!(family, report, bindings \\ nil)
      when is_binary(family) and is_map(report) do
    config = family_config!(family)
    bindings = bindings || source_bindings(family)
    validate_fixture_authority!()

    validate_report!(report,
      authority_ledger_sha256: bindings["authority_ledger_sha256"]
    )

    imp = local_observations(family)
    dspy = get_in(report, ["observations", family])

    unless imp == dspy do
      raise ArgumentError, "#{family} Imp observations differ from pinned DSPy observations"
    end

    scope = get_in(fixture(), ["scopes", family])

    %{
      "schema_version" => 1,
      "protocol_id" => config.protocol_id,
      "registry_protocol_id" => config.registry_id,
      "family" => family,
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
        "retained_exclusions" => scope["not_claimed"]
      }
    }
  end

  @doc false
  def validate_artifact!(registry_protocol_id, artifact)
      when is_binary(registry_protocol_id) and is_map(artifact) do
    {family, _config} =
      Enum.find(@families, fn {_family, config} -> config.registry_id == registry_protocol_id end) ||
        raise(ArgumentError, "unknown classical optimizer protocol #{registry_protocol_id}")

    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)
    artifact_bindings = artifact["source_bindings"]
    current_bindings = source_bindings(family)

    unless get_in(artifact, ["run_context", "workspace", "state"]) == "clean" do
      raise ArgumentError, "#{family} C1 admission requires a clean checkout"
    end

    unless is_map(artifact_bindings) and
             committed_sources_match?(artifact["git_sha"], family, artifact_bindings) and
             get_in(artifact, ["run_context", "inputs"]) == artifact_bindings do
      raise ArgumentError, "#{family} C1 artifact is not bound to committed Imp source"
    end

    unless semantic_bindings(artifact_bindings) == semantic_bindings(current_bindings) and
             optimizer_semantics_match?(artifact["git_sha"], family) do
      raise ArgumentError, "#{family} C1 artifact does not match current semantic sources"
    end

    expected = build_artifact!(family, artifact["dspy_receipt"], artifact_bindings)

    unless Map.drop(artifact, ["generated_at", "git_sha", "run_context"]) == expected do
      raise ArgumentError, "#{family} C1 artifact content does not recompute"
    end

    artifact
  end

  @doc false
  def validate_report!(report, opts \\ []) when is_map(report) and is_list(opts) do
    fixture = fixture()
    validate_report_envelope!(report, fixture)

    validate_report_source!(
      report,
      fixture["source"],
      Keyword.get(opts, :authority_ledger_sha256, file_sha256!(@ledger_path))
    )

    report
  end

  defp validate_report_source!(report, source, authority_ledger_sha256) do
    runtime = report["runtime_identity"]

    expected_runtime = %{
      "authority_ledger_sha256" => String.replace_prefix(authority_ledger_sha256, "sha256:", ""),
      "authority_manifest_sha256" => raw_file_sha256!(@authority_path),
      "authority_manifest_verified_files" => source["source_manifest"]["file_count"],
      "distribution_version" => source["version"],
      "git_clean" => true,
      "git_commit" => @dspy_commit,
      "git_tag" => source["version"],
      "module_version" => "3.2.0",
      "source_root" => @dspy_source
    }

    unless runtime == expected_runtime and
             report["fixture_identity"] == %{
               "script_sha256" => raw_file_sha256!(@script_path),
               "config_sha256" => raw_file_sha256!(@config_path)
             } do
      raise ArgumentError,
            "classical optimizer sidecar is not bound to pinned source and fixtures"
    end
  end

  defp validate_report_envelope!(report, fixture) do
    required =
      ~w(credential_environment fixture_id fixture_identity isolation observations runner runtime_identity schema_version scopes source status)

    expected_observations = %{
      "bootstrap_few_shot" => get_in(fixture, ["bootstrap_few_shot", "expected"]),
      "random_search" => get_in(fixture, ["random_search", "expected"])
    }

    expected_identity = %{
      "schema_version" => 1,
      "fixture_id" => fixture["fixture_id"],
      "runner" => "python-dspy-classical-optimizer-differential",
      "status" => "passing",
      "source" => fixture["source"],
      "scopes" => fixture["scopes"],
      "isolation" => %{"isolated_process" => true},
      "credential_environment" => %{"provider_credential_names_present" => []},
      "observations" => expected_observations
    }

    unless Enum.sort(Map.keys(report)) == Enum.sort(required) and
             Map.take(report, Map.keys(expected_identity)) == expected_identity do
      raise ArgumentError, "classical optimizer sidecar receipt or observations are invalid"
    end
  end

  @doc false
  def local_observations("bootstrap_few_shot") do
    config = fixture()["bootstrap_few_shot"]
    rows = examples(config["trainset"])

    student =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "generated"} end)
      )

    metric = fn example, prediction ->
      Imp.Example.get(example, :answer) == Imp.get(prediction, :answer)
    end

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(metric,
        max_bootstrapped_demos: config["max_bootstrapped_demos"],
        max_labeled_demos: config["max_labeled_demos"],
        max_rounds: config["max_rounds"],
        max_errors: 10
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(student, rows)

    report = Report.fetch(compiled)
    demos = Enum.map(compiled.demos, &Imp.Example.to_map/1)

    %{
      "teacher_questions" =>
        Enum.map(report.candidates, &Enum.at(config["trainset"], &1.index)["question"]),
      "accepted_questions" => Enum.map(demos, &to_string(&1.question)),
      "augmented_answers" => Enum.map(demos, &to_string(&1.answer)),
      "attempt_count" => report.metadata.bootstrap_attempts,
      "compiled_demo_count" => length(demos)
    }
  end

  def local_observations("random_search") do
    config = fixture()["random_search"]
    rows = examples(config["trainset"])
    valset = examples(config["valset"])
    answers = Map.new(config["trainset"] ++ config["valset"], &{&1["question"], "constant"})
    metric = Imp.Metrics.exact_match(:answer)

    report =
      BootstrapFewShotWithRandomSearch.new(metric,
        num_candidate_programs: config["num_candidate_programs"],
        max_bootstrapped_demos: config["max_bootstrapped_demos"],
        max_labeled_demos: config["max_labeled_demos"],
        max_rounds: config["max_rounds"],
        max_errors: 10,
        num_threads: 1
      )
      |> BootstrapFewShotWithRandomSearch.compile(fixture_program(answers), rows, valset,
        restrict: config["restrict"]
      )
      |> then(fn compiled -> Report.fetch(compiled.main) end)

    candidates = report.candidates

    %{
      "candidate_seeds" => report.metadata.candidate_seeds,
      "candidate_kinds" => Enum.map(candidates, &Atom.to_string(&1.kind)),
      "ranked_seeds" => Enum.map(candidates, & &1.seed),
      "demo_counts" => Enum.map(candidates, &length(&1.demos.main)),
      "scores" => Enum.map(candidates, & &1.score),
      "subscores" => Enum.map(candidates, & &1.subscores)
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
      "authority_ledger_sha256" => file_sha256!(@ledger_path),
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

  defp run_python!(python) do
    case System.cmd(
           python,
           [Path.expand(@script_path), "--config", Path.expand(@config_path)],
           cd: File.cwd!(),
           env: credential_safe_python_env(),
           stderr_to_stdout: false
         ) do
      {output, 0} -> Jason.decode!(output)
      {output, status} -> Mix.raise("classical optimizer sidecar failed #{status}: #{output}")
    end
  end

  defp validate_fixture_authority! do
    fixture = fixture()
    source = fixture["source"]
    manifest = read_json!(@authority_path)
    ledger = read_json!(@ledger_path)
    family = Enum.find(ledger["families"], &(&1["id"] == source["authority_family"]))
    canonical = family && family["upstream_repository"]

    unless canonical_authority?(source, canonical, manifest) do
      raise ArgumentError, "classical optimizer fixture is not bound to canonical DSPy authority"
    end

    manifest_files = Map.new(manifest["files"], &{&1["path"], &1["sha256"]})
    validate_authority_sources!(source, manifest_files)
    validate_upstream_tests!(source, family)
  end

  defp validate_authority_sources!(source, manifest_files) do
    Enum.each(~w(bootstrap_source random_search_source), fn key ->
      entry = source[key]

      unless manifest_files[entry["path"]] == entry["sha256"],
        do: raise(ArgumentError, "#{key} is absent from authority manifest")
    end)
  end

  defp validate_upstream_tests!(source, family) do
    references = get_in(family, ["upstream_tests", "references"]) || []

    Enum.each(~w(bootstrap_upstream_test random_search_upstream_test), fn key ->
      entry = source[key]

      unless "#{entry["path"]}#sha256=#{entry["sha256"]}" in references,
        do: raise(ArgumentError, "#{key} is absent from authority ledger")
    end)
  end

  defp canonical_authority?(source, canonical, manifest) do
    identity_fields = ~w(repository version git_ref commit source_manifest)

    is_map(canonical) and
      Map.take(source, identity_fields) == Map.take(canonical, identity_fields) and
      source["commit"] == @dspy_commit and manifest["commit"] == @dspy_commit and
      source["source_manifest"]["path"] == @authority_path and
      source["source_manifest"]["sha256"] == raw_file_sha256!(@authority_path) and
      source["source_manifest"]["file_count"] == length(manifest["files"] || [])
  end

  defp fixture_program(answers) do
    %FixtureProgram{main: Imp.predict("question -> answer"), answers: answers}
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.example(question: row["question"], answer: row["answer"]) |> Imp.with_inputs(:question)
    end)
  end

  defp family_slug(family), do: String.replace(family, "_", "-")

  defp family_config!(family),
    do:
      Map.get(@families, family) ||
        raise(ArgumentError, "unknown classical optimizer family #{inspect(family)}")

  defp fixture, do: read_json!(@config_path)

  defp credential_env_name?(name) do
    upper = String.upcase(name)

    upper == "PGPASSWORD" or
      Enum.any?(
        ~w(API_KEY ACCESS_KEY ACCESS_TOKEN AUTHORIZATION AUTH_TOKEN BEARER_TOKEN CLIENT_SECRET CREDENTIAL CREDENTIALS DATABASE_URL PASSWORD PRIVATE_KEY SECRET SECRET_KEY TOKEN COOKIE CONNECTION_STRING),
        &(upper == &1 or String.ends_with?(upper, "_" <> &1))
      )
  end

  defp committed_sources_match?(git_sha, family, bindings) when is_binary(git_sha) do
    config = family_config!(family)

    files = [
      {@task_path, "task_sha256"},
      {@script_path, "script_sha256"},
      {@config_path, "config_sha256"},
      {@authority_path, "authority_manifest_sha256"},
      {@ledger_path, "authority_ledger_sha256"},
      {config.source_path, "imp_optimizer_source_sha256"}
    ]

    Regex.match?(~r/^[0-9a-f]{40}$/, git_sha) and
      Enum.all?(files, fn {path, key} ->
        case System.cmd("git", ["show", "#{git_sha}:#{path}"], stderr_to_stdout: true) do
          {bytes, 0} -> "sha256:" <> raw_sha256(bytes) == bindings[key]
          _ -> false
        end
      end)
  end

  defp committed_sources_match?(_, _, _), do: false

  defp optimizer_semantics_match?(git_sha, family) do
    source_path = family_config!(family).source_path

    with {historical, 0} <-
           System.cmd("git", ["show", "#{git_sha}:#{source_path}"], stderr_to_stdout: true) do
      Imp.BenchmarkTruth.SemanticSource.digest(historical) ==
        source_path |> File.read!() |> Imp.BenchmarkTruth.SemanticSource.digest()
    else
      _ -> false
    end
  end

  # The authority ledger and task are multi-family control files. The optimizer
  # file is compared separately as normalized Elixir syntax so documentation,
  # comments, and source locations do not masquerade as behavioral changes.
  defp semantic_bindings(bindings) when is_map(bindings),
    do:
      Map.drop(bindings, [
        "authority_ledger_sha256",
        "task_sha256",
        "imp_optimizer_source_sha256"
      ])

  defp default_python, do: Path.expand("tmp/dspy-parity-venv/bin/python")
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp file_sha256!(path), do: "sha256:" <> raw_file_sha256!(path)
  defp raw_file_sha256!(path), do: path |> File.read!() |> raw_sha256()
  defp raw_sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end

defmodule Mix.Tasks.Imp.Benchmark.BootstrapFewShotDifferential do
  @moduledoc "Capture provider-free BootstrapFewShot C1 differential evidence."
  use Mix.Task
  @shortdoc "Capture provider-free BootstrapFewShot C1 evidence"
  @impl true
  def run(args),
    do:
      Mix.Tasks.Imp.Benchmark.ClassicalOptimizerDifferential.run_family(
        "bootstrap_few_shot",
        args
      )
end

defmodule Mix.Tasks.Imp.Benchmark.RandomSearchDifferential do
  @moduledoc "Capture provider-free BootstrapFewShotWithRandomSearch C1 differential evidence."
  use Mix.Task
  @shortdoc "Capture provider-free BootstrapFewShotWithRandomSearch C1 evidence"
  @impl true
  def run(args),
    do: Mix.Tasks.Imp.Benchmark.ClassicalOptimizerDifferential.run_family("random_search", args)
end

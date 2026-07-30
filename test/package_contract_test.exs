defmodule PackageContractTest do
  use ExUnit.Case, async: false

  @moduletag :package

  @product_files [
    "lib/imp.ex",
    "lib/imp/clients/req_llm.ex",
    "lib/imp/lm/static.ex",
    "priv/public_api.json",
    "CHANGELOG.md",
    "LICENSE",
    "RELEASE_NOTES.md",
    "README.md",
    "docs/API_GUIDE.md",
    "examples/deployment/lib/imp_deployment/program_server.ex",
    "examples/deployment/lib/imp_deployment/support_pipeline.ex",
    "examples/deployment/lib/imp_deployment/workflow.ex",
    "examples/deployment/load_workflow.exs",
    "examples/deployment/run_workflow.exs",
    "examples/provider_free_ticket_router/README.md",
    "examples/provider_free_ticket_router/mix.exs",
    "examples/provider_free_ticket_router/run.exs",
    "livebooks/01_real_lm_front_door.livemd",
    "livebooks/02_programming_not_prompting.livemd"
  ]

  @product_dataset_files [
    "benchmarks/data/grpo-usefulness-banking77-v1.json",
    "benchmarks/data/simba-trec-coarse-v1.json"
  ]

  @repository_files [
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "SECURITY.md",
    ".github/dependabot.yml",
    ".github/pull_request_template.md",
    ".github/workflows/ci.yml"
  ]

  @excluded_prefixes [
    "benchmarks/config/",
    "benchmarks/evidence/",
    "benchmarks/results/",
    "lib/imp/benchmark_env.ex",
    "lib/mix/tasks/imp.benchmark",
    "lib/mix/tasks/imp.gate_evidence.ex",
    "bench/",
    "lib/imp/identity_progress/",
    "scripts/dspy_",
    "test/",
    "tmp/"
  ]

  @excluded_files [
    "docs/internal/BENCHMARK_CATALOG.md",
    "docs/internal/BENCHMARK_TRUTH.md",
    "docs/internal/COVERAGE_MATRIX.md",
    "docs/internal/PARITY_VALIDATION_PROGRAM.md",
    "docs/maintainers/RELEASE.md",
    "docs/maintainers/EVIDENCE.md",
    "bench/imp/legacy_identity_audit.ex",
    "lib/imp/benchmarks.ex",
    "lib/mix/tasks/imp.evidence.admit.ex",
    "lib/mix/tasks/imp.public_api.ex",
    "lib/mix/tasks/imp.package.clean_room.ex",
    "bench/imp/evidence_authorities.ex",
    "bench/imp/research_portfolio.ex",
    "bench/imp/upstream_authority_registry.ex",
    "bench/imp/upstream_fidelity.ex",
    "priv/public_api_policy.json"
  ]

  @documented_module_allowlist MapSet.new([
                                 "Imp.Optimize",
                                 "Imp.Optimizer",
                                 "Imp.TaskSupervisor",
                                 "Imp.UnlinkedTaskSupervisor"
                               ])

  test "Hex package ships product code and docs, not local evidence machinery" do
    files =
      Mix.Project.config()
      |> Keyword.fetch!(:package)
      |> Keyword.fetch!(:files)
      |> Enum.sort()

    assert_release_files(files)
  end

  test "clean-room package gate is discoverable from the root Mix project" do
    assert Mix.Task.get("imp.package.clean_room") == Mix.Tasks.Imp.Package.CleanRoom

    assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
             Code.fetch_docs(Mix.Tasks.Imp.Package.CleanRoom)

    assert moduledoc =~ "mix imp.package.clean_room"
    assert moduledoc =~ "--lock"
    assert moduledoc =~ "source checkout's `mix.lock`"
    assert moduledoc =~ "provider-free"

    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)
    assert hd(Keyword.fetch!(aliases, :"package.check")) == "package.clean"
    assert is_list(Keyword.fetch!(aliases, :"package.clean"))
  end

  test "source checkout retains its local research task surface" do
    assert Mix.Task.get("imp.benchmark.run") == Mix.Tasks.Imp.Benchmark.Run
    assert Mix.Task.get("imp.package.clean_room") == Mix.Tasks.Imp.Package.CleanRoom
    assert Code.ensure_loaded?(Imp.BenchmarkTruth)
    assert Code.ensure_loaded?(Imp.Optimizer.Playbook.Campaign)
  end

  @tag timeout: 180_000
  test "ordinary path consumption compiles only the quiet runtime surface" do
    root = File.cwd!()
    consumer = Path.join(root, "tmp/path-dependency-contract")
    File.rm_rf!(consumer)
    File.mkdir_p!(consumer)

    File.write!(
      Path.join(consumer, "mix.exs"),
      """
      defmodule ImpPathConsumer.MixProject do
        use Mix.Project

        def project do
          [
            app: :imp_path_consumer,
            version: "0.0.0",
            elixir: "~> 1.19",
            deps: [{:imp, path: #{inspect(root)}}]
          ]
        end
      end
      """
    )

    File.cp!(Path.join(root, "mix.lock"), Path.join(consumer, "mix.lock"))
    on_exit(fn -> File.rm_rf(consumer) end)

    {get_output, get_status} =
      System.cmd("mix", ["deps.get"],
        cd: consumer,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert get_status == 0, get_output

    {output, status} =
      System.cmd("mix", ["compile"],
        cd: consumer,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "==> imp\nCompiling"

    imp_output = output |> String.split("==> imp\n") |> List.last()
    refute imp_output =~ "warning:"

    beams =
      consumer
      |> Path.join("_build/dev/lib/imp/ebin/*.beam")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    assert "Elixir.Imp.beam" in beams
    refute Enum.any?(beams, &String.starts_with?(&1, "Elixir.Mix.Tasks.Imp."))
    refute "Elixir.Imp.BenchmarkTruth.beam" in beams
    refute "Elixir.Imp.Optimizer.Playbook.Campaign.beam" in beams
  end

  test "root project declares the Imp OTP application contract" do
    assert Mix.Project.config()[:app] == :imp
    assert Imp.MixProject.application()[:mod] == {Imp.Application, []}
  end

  test "clean-room output guard accepts siblings but rejects deleting its package input" do
    guard = &Mix.Tasks.Imp.Package.CleanRoom.output_contains_package?/2

    refute guard.("tmp/package-clean-room", "tmp/package-check")
    assert guard.("tmp/package-check", "tmp/package-check")
    assert guard.("tmp", "tmp/package-check")
  end

  test "package exclusion list names current repository files" do
    assert Enum.all?(@excluded_files, &File.regular?/1)
  end

  test "repository includes release and security stewardship files" do
    assert Enum.all?(@repository_files, &File.regular?/1)
    assert File.read!("LICENSE") =~ "MIT License"
    assert File.read!("SECURITY.md") =~ "Reporting a Vulnerability"
  end

  @tag timeout: 180_000
  test "unpacked Hex artifact preserves the release boundary" do
    output_dir = package_tmp_dir()

    on_exit(fn -> File.rm_rf(output_dir) end)

    {output, status} =
      System.cmd(
        "mix",
        ["hex.build", "--unpack", "--output", output_dir],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    assert status == 0, output

    files =
      output_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, output_dir))
      |> Enum.sort()

    assert_release_files(files)
    assert_manifest_sources_are_shipped(output_dir, files)
    assert_unpacked_mix_surface(output_dir)
    assert_unpacked_package_can_be_consumed(output_dir)
  end

  test "shipped docs do not reference modules excluded from the Hex package" do
    files =
      Mix.Project.config()
      |> Keyword.fetch!(:package)
      |> Keyword.fetch!(:files)
      |> Enum.sort()

    package_file_set = MapSet.new(files)

    missing =
      files
      |> Enum.filter(&String.match?(&1, ~r/^(README\.md|docs\/.*\.md|livebooks\/.*\.livemd)$/))
      |> documented_module_references()
      |> Enum.reject(&MapSet.member?(@documented_module_allowlist, &1))
      |> Enum.reject(fn module_name ->
        module_name
        |> module_from_string()
        |> module_source_file()
        |> then(&MapSet.member?(package_file_set, &1))
      end)

    assert missing == []
  end

  test "shipped docs do not point readers at files excluded from the Hex package" do
    files =
      Mix.Project.config()
      |> Keyword.fetch!(:package)
      |> Keyword.fetch!(:files)
      |> Enum.sort()

    package_file_set = MapSet.new(files)

    missing =
      files
      |> Enum.filter(&String.match?(&1, ~r/^(README\.md|docs\/.*\.md|livebooks\/.*\.livemd)$/))
      |> documented_file_references()
      |> Enum.reject(&MapSet.member?(package_file_set, &1))

    assert missing == []
  end

  test "shipped docs label source-checkout commands as source-checkout commands" do
    files =
      Mix.Project.config()
      |> Keyword.fetch!(:package)
      |> Keyword.fetch!(:files)
      |> Enum.filter(&String.match?(&1, ~r/^(README\.md|docs\/.*\.md|livebooks\/.*\.livemd)$/))

    unqualified =
      files
      |> Enum.flat_map(&unqualified_source_checkout_command_mentions/1)
      |> Enum.sort()

    assert unqualified == []
  end

  test "README states the honest install: source checkout now, Hex pending publication" do
    readme = File.read!("README.md")

    # Honesty pass (dee-6yen): the Hex package is not published and the
    # repository is private, so the README may not advertise a Hex or
    # github: install as currently working. The Hex line may appear only as
    # the stated future install, and the working path is a source checkout.
    assert readme =~ "not yet published to Hex"
    assert readme =~ ~s({:imp, path:)
    assert readme =~ "source checkout"
    refute readme =~ ~s({:imp, github: "deepfates/imp")
    refute readme =~ "Documentation lives at [hexdocs.pm/imp]"

    # When the owner publishes to Hex (step 2 of dee-6yen), restore the
    # Hex-first wording and re-pin this test to it.
  end

  defp assert_release_files(files) do
    for file <- @product_files do
      assert file in files
    end

    for prefix <- @excluded_prefixes do
      refute Enum.any?(files, &String.starts_with?(&1, prefix))
    end

    refute Enum.any?(files, fn path ->
             path |> Path.split() |> Enum.any?(&(&1 in ["_build", "deps"]))
           end)

    for file <- @excluded_files do
      refute file in files
    end

    assert Enum.sort(Enum.filter(files, &String.starts_with?(&1, "benchmarks/"))) ==
             Enum.sort(@product_dataset_files)

    refute Enum.any?(files, &String.starts_with?(&1, "lib/mix/tasks/"))
  end

  defp package_tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "imp-package-contract-#{System.unique_integer([:positive])}"
    ])
  end

  defp assert_unpacked_mix_surface(output_dir) do
    script = """
    Mix.start()
    Code.require_file("mix.exs")

    aliases =
      Mix.Project.config()
      |> Keyword.fetch!(:aliases)
      |> Keyword.keys()
      |> Enum.map(&to_string/1)

    preferred_envs =
      Imp.MixProject.cli()
      |> Keyword.fetch!(:preferred_envs)
      |> Keyword.keys()
      |> Enum.map(&to_string/1)

    if Mix.Project.config()[:app] != :imp do
      raise "unpacked package changed its OTP application name"
    end

    if Imp.MixProject.application()[:mod] != {Imp.Application, []} do
      raise "unpacked package changed its OTP application module"
    end

    if aliases != [] or preferred_envs != [] do
      raise "unpacked package exposes source-checkout Mix surface: \#{inspect(%{aliases: aliases, preferred_envs: preferred_envs})}"
    end
    """

    {output, status} =
      System.cmd("elixir", ["-e", script],
        cd: output_dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp assert_unpacked_package_can_be_consumed(package_dir) do
    consumer_dir = consumer_tmp_dir()
    on_exit(fn -> File.rm_rf(consumer_dir) end)

    mix_exs = """
    defmodule ImpConsumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :imp_consumer,
          version: "0.1.0",
          elixir: "~> 1.19",
          deps: [{:imp, path: #{inspect(package_dir)}}]
        ]
      end
    end
    """

    File.mkdir_p!(consumer_dir)
    File.write!(Path.join(consumer_dir, "mix.exs"), mix_exs)

    script = """
    case Application.load(:imp) do
      :ok -> :ok
      {:error, {:already_loaded, :imp}} -> :ok
    end

    unless Application.spec(:imp, :mod) == {Imp.Application, []} do
      raise "package consumer did not load :imp with Imp.Application"
    end

    unless Code.ensure_loaded?(Imp) and Application.get_application(Imp) == :imp do
      raise "package consumer could not resolve Imp through :imp"
    end

    canonicalize = fn path ->
      {resolved, 0} = System.cmd("realpath", [Path.expand(path)])
      String.trim(resolved)
    end

    manifest =
      #{inspect(Path.join(package_dir, "priv/public_api.json"))}
      |> File.read!()
      |> Jason.decode!()

    for entry <- manifest["modules"] do
      module = Module.concat(String.split(entry["module"], "."))

      unless module in Application.spec(:imp, :modules) do
        raise "manifest module is absent from the unpacked application: \#{entry["module"]}"
      end

      unless Code.ensure_loaded?(module) do
        raise "manifest module could not be loaded from the unpacked artifact: \#{entry["module"]}"
      end

      source =
        module.module_info(:compile)
        |> Keyword.fetch!(:source)
        |> List.to_string()
        |> Path.expand()
        |> canonicalize.()

      expected_source =
        #{inspect(package_dir)}
        |> Path.join(entry["source"])
        |> Path.expand()
        |> canonicalize.()

      unless source == expected_source do
        raise "manifest source binding mismatch for \#{entry["module"]}: expected \#{expected_source}, got \#{source}"
      end
    end

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    Imp.configure(lm: lm, adapter: Imp.Adapter.Chat)

    program =
      "question -> answer: short_span"
      |> Imp.signature("Answer with the shortest correct span. Do not explain.")
      |> Imp.predict()

    {:ok, prediction} =
      Imp.call(program, %{question: "What city is the Eiffel Tower in?"})

    unless Imp.get(prediction, :answer) == "Paris" do
      raise "unexpected Imp prediction: \#{inspect(prediction)}"
    end

    demo =
      Imp.example(question: "What city is the Eiffel Tower in?", answer: "Paris")
      |> Imp.with_inputs([:question])

    compiled =
      Imp.optimize!(
        program,
        Imp.Optimizer.LabeledFewShot.new(k: 1),
        [demo]
      )

    {:ok, compiled_prediction} =
      Imp.call(compiled, %{question: "What city is the Eiffel Tower in?"})

    unless Imp.get(compiled_prediction, :answer) == "Paris" do
      raise "optimized program did not remain executable"
    end

    metric = Imp.exact_match(:answer)
    report = Imp.evaluate(compiled, [demo], metric)

    unless report.score == 1.0 do
      raise "facade metric/evaluation path failed from package consumer: \#{inspect(report)}"
    end

    loaded =
      compiled
      |> Imp.dump()
      |> Imp.load()

    {:ok, loaded_prediction} =
      Imp.call(loaded, %{question: "What city is the Eiffel Tower in?"})

    unless Imp.get(loaded_prediction, :answer) == "Paris" do
      raise "saved and loaded program did not remain executable"
    end

    defmodule ImpConsumer.NativeArtifactStrategy do
      @behaviour Imp.Optimize.Anything.StructuredStrategy

      @impl true
      def propose(candidate, dataset, components, config) do
        unless is_boolean(candidate["enabled"]) and is_integer(candidate["retries"]) and
                 is_map(candidate["policy"]) and is_list(candidate["policy"]["weights"]) and
                 is_map(dataset) and Enum.sort(components) == ["enabled", "policy", "retries"] do
          raise "packaged strategy did not receive the native structured artifact"
        end

        {:ok, config["target"], %{"source" => "cold-consumer"}}
      end
    end

    defmodule ImpConsumer.MalformedArtifactStrategy do
      @behaviour Imp.Optimize.Anything.StructuredStrategy

      @impl true
      def propose(candidate, _dataset, _components, _config),
        do: Map.delete(candidate, "retries")
    end

    seed_artifact = %{
      "enabled" => false,
      "policy" => %{"route" => "slow", "weights" => [1.0, 0.0]},
      "retries" => 1
    }

    selected_artifact = %{
      "enabled" => true,
      "policy" => %{"route" => "fast", "weights" => [0.25, 0.75]},
      "retries" => 3
    }

    strategy =
      Imp.Optimize.Anything.StructuredStrategy.new(
        ImpConsumer.NativeArtifactStrategy,
        id: "package-routing/v1",
        config: %{"target" => selected_artifact}
      )

    {:ok, oa_calls} = Agent.start_link(fn -> 0 end)

    artifact_evaluator = fn artifact, _example ->
      Agent.update(oa_calls, &(&1 + 1))
      matches = Enum.count(selected_artifact, fn {key, value} -> artifact[key] == value end)
      matches / map_size(selected_artifact)
    end

    oa_config = [
      engine: [max_candidate_proposals: 1, seed: 29],
      reflection: [module_selector: :all, structured_strategy: strategy]
    ]

    oa_result =
      Imp.Optimize.Anything.run(seed_artifact, artifact_evaluator,
        dataset: [%{"split" => "train"}],
        valset: [%{"split" => "selection"}],
        config: oa_config
      )

    unless seed_artifact["enabled"] == false and
             Imp.Optimize.Anything.best_candidate(oa_result) == selected_artifact do
      raise "packaged structured strategy did not select an immutable native artifact"
    end

    applied = Imp.Optimize.Anything.best_candidate(oa_result)

    unless applied["enabled"] and applied["retries"] == 3 and
             applied["policy"]["route"] == "fast" do
      raise "selected native artifact was not directly applicable by the consumer"
    end

    persisted_selected = applied |> Jason.encode!() |> Jason.decode!()
    persisted_checkpoint = oa_result.checkpoint |> Jason.encode!() |> Jason.decode!()
    calls_before_resume = Agent.get(oa_calls, & &1)

    resumed =
      Imp.Optimize.Anything.run(seed_artifact, artifact_evaluator,
        dataset: [%{"split" => "train"}],
        valset: [%{"split" => "selection"}],
        config: oa_config,
        resume_state: persisted_checkpoint
      )

    unless Imp.Optimize.Anything.best_candidate(resumed) == persisted_selected and
             Agent.get(oa_calls, & &1) == calls_before_resume do
      raise "packaged structured strategy did not resume exactly from saved state"
    end

    malformed =
      Imp.Optimize.Anything.StructuredStrategy.new(
        ImpConsumer.MalformedArtifactStrategy,
        id: "package-malformed/v1"
      )

    rejected =
      Imp.Optimize.Anything.run(seed_artifact, fn _artifact -> 0.0 end,
        config: [
          engine: [max_candidate_proposals: 1, raise_on_exception: false],
          reflection: [module_selector: :all, structured_strategy: malformed]
        ]
      )

    unless Imp.Optimize.Anything.best_candidate(rejected) == seed_artifact and
             inspect(rejected.rejected) =~ "invalid_structured_strategy_candidate" do
      raise "packaged structured proposal validation admitted a partial artifact"
    end

    # This deterministic package contract proves public construction,
    # validation, selection, application, and resume—not artifact-strategy
    # effectiveness on an untouched task.

    # Package lifecycle fixture only: these planted Static LMs prove that the
    # unpacked artifact can construct the named core optimizer families, attach
    # their reports where applicable, and execute the returned programs. The
    # task LM always returns Paris, so this is constructor/report/call lifecycle
    # coverage, not proof that a candidate was applied, effective, or general.
    fixture_trainset = [
      Imp.example(question: "Train: French landmark city?", answer: "Paris")
      |> Imp.with_inputs(:question),
      Imp.example(question: "Train: French capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    fixture_selection_set = [
      Imp.example(question: "Selection: Seine city?", answer: "Paris")
      |> Imp.with_inputs(:question),
      Imp.example(question: "Selection: Louvre city?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    fixture_testset = [
      Imp.example(question: "Test: Arc de Triomphe city?", answer: "Paris")
      |> Imp.with_inputs(:question),
      Imp.example(question: "Test: Notre-Dame city?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    prompt_lm = fn response ->
      Imp.LM.Static.new(handler: fn _messages, _opts -> response end)
    end

    verify_program_optimizer = fn name, expected_report, optimized ->
      case Imp.Optimizer.Report.fetch(optimized) do
        %Imp.Optimizer.Report{optimizer: ^expected_report} -> :ok
        other -> raise "\#{name} package lifecycle report mismatch: \#{inspect(other)}"
      end

      case Imp.call(optimized, %{question: "Package lifecycle call"}) do
        {:ok, prediction} ->
          unless Imp.get(prediction, :answer) == "Paris" do
            raise "\#{name} package lifecycle call returned \#{inspect(prediction)}"
          end

        other ->
          raise "\#{name} package lifecycle call failed: \#{inspect(other)}"
      end

      case Imp.evaluate(optimized, fixture_testset, metric) do
        %Imp.Evaluate.Result{score: 1.0} -> :ok
        other -> raise "\#{name} package lifecycle test rows failed: \#{inspect(other)}"
      end
    end

    labeled_few_shot =
      Imp.optimize!(
        program,
        Imp.Optimizer.LabeledFewShot.new(k: 1, sample: false),
        fixture_trainset
      )

    verify_program_optimizer.(
      :labeled_few_shot,
      :labeled_few_shot,
      labeled_few_shot
    )

    unless match?(%Imp.Predict.Predict{demos: [_]}, labeled_few_shot) do
      raise "LabeledFewShot package lifecycle did not attach its selected demonstration"
    end

    bootstrap_few_shot =
      Imp.optimize!(
        program,
        Imp.Optimizer.BootstrapFewShot.new(metric,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 0
        ),
        fixture_trainset
      )

    verify_program_optimizer.(
      :bootstrap_few_shot,
      :bootstrap_few_shot,
      bootstrap_few_shot
    )

    unless match?(%Imp.Predict.Predict{demos: [_]}, bootstrap_few_shot) do
      raise "BootstrapFewShot package lifecycle did not attach its accepted trace"
    end

    random_search =
      Imp.optimize!(
        program,
        Imp.Optimizer.RandomSearch.new(metric,
          num_candidate_programs: 0,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 1
        ),
        fixture_trainset,
        fixture_selection_set
      )

    verify_program_optimizer.(
      :random_search,
      :random_search,
      random_search
    )

    random_deployed =
      random_search
      |> Imp.Optimizer.Artifact.from_optimized_program()
      |> Imp.Optimizer.Artifact.apply(program)

    unless match?(
             %Imp.Optimizer.Report{optimizer: :random_search},
             Imp.Optimizer.Report.fetch(random_deployed)
           ) do
      raise "RandomSearch package artifact lost its optimizer report on application"
    end

    verify_program_optimizer.(:random_search_artifact, :random_search, random_deployed)

    knn_few_shot =
      Imp.Optimizer.KNNFewShot.new(1, fixture_trainset,
        vectorizer: Imp.Embeddings.BagOfWords,
        few_shot_bootstrap_args: [
          metric: metric,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 0
        ]
      )
      |> Imp.Optimizer.KNNFewShot.compile(program)

    case Imp.call(knn_few_shot, %{question: "Test: nearest French city?"}) do
      {:ok, %Imp.Prediction{metadata: %{knn_few_shot: %{demo_count: 1}}}} -> :ok
      other -> raise "KNNFewShot package lifecycle call failed: \#{inspect(other)}"
    end

    unless Imp.evaluate(knn_few_shot, fixture_testset, metric).score == 1.0 do
      raise "KNNFewShot package lifecycle test rows failed"
    end

    copro =
      Imp.Optimizer.COPRO.new(metric,
        breadth: 2,
        depth: 1,
        proposer_lm:
          prompt_lm.(
            Jason.encode!(%{
              "proposed_instruction" => "Answer with the city only.",
              "proposed_prefix_for_output_field" => "Answer:"
            })
          )
      )

    verify_program_optimizer.(
      :copro,
      :copro,
      Imp.optimize!(program, copro, fixture_trainset, fixture_selection_set)
    )

    mipro_v2 =
      Imp.Optimizer.MIPROv2.new(metric,
        auto: nil,
        num_candidates: 2,
        num_trials: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        startup_trials: 1,
        prompt_lm: prompt_lm.(%{"instructions" => ["Answer with the city only."]})
      )

    verify_program_optimizer.(
      :mipro_v2,
      :mipro_v2,
      Imp.optimize!(program, mipro_v2, fixture_trainset, fixture_selection_set)
    )

    simba =
      Imp.Optimizer.SIMBA.new(metric,
        bsize: 1,
        num_candidates: 2,
        max_steps: 1,
        max_demos: 0,
        seed: 3,
        prompt_lm:
          prompt_lm.(%{
            discussion: "Keep returning the requested city.",
            module_advice: %{main: "Answer with the city only."}
          })
      )

    verify_program_optimizer.(
      :simba,
      :simba,
      Imp.optimize!(program, simba, fixture_trainset, fixture_selection_set)
    )

    gepa =
      Imp.Optimizer.GEPA.new(metric,
        generations: 1,
        minibatch_size: 1,
        seed: 3,
        reflection_lm: prompt_lm.(%{instruction: "Answer with the city only."})
      )

    verify_program_optimizer.(
      :gepa,
      :gepa,
      Imp.optimize!(program, gepa, fixture_trainset, fixture_selection_set)
    )

    infer_rules =
      Imp.Optimizer.InferRules.new(metric,
        num_candidates: 1,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        rule_lm:
          prompt_lm.(%{
            reasoning: "Every fixture requests the same city.",
            natural_language_rules: "Answer with the city only."
          })
      )

    verify_program_optimizer.(
      :infer_rules,
      :infer_rules,
      Imp.optimize!(program, infer_rules, fixture_trainset, fixture_selection_set)
    )

    signature_optimizer =
      Imp.Optimizer.SignatureOptimizer.new(metric,
        candidates: ["Answer with the city only."]
      )

    signature_optimized =
      Imp.optimize!(
        program,
        signature_optimizer,
        fixture_trainset,
        fixture_selection_set
      )

    verify_program_optimizer.(
      :signature_optimizer,
      :signature_optimizer,
      signature_optimized
    )

    unless Imp.Optimizer.InstructionSearch.current_instruction(signature_optimized) ==
             Imp.Optimizer.InstructionSearch.current_instruction(program) do
      raise "SignatureOptimizer package lifecycle did not protect its equal-score baseline"
    end

    ensemble =
      Imp.Optimizer.Ensemble.new(deterministic: true)
      |> Imp.Optimizer.Ensemble.compile([program, signature_optimized])

    case Imp.call(ensemble, %{question: "Package ensemble call"}) do
      {:ok, %Imp.Prediction{fields: %{outputs: outputs}}} when length(outputs) == 2 ->
        unless Enum.all?(outputs, fn
                 {:ok, prediction} -> Imp.get(prediction, :answer) == "Paris"
                 _other -> false
               end) do
          raise "Ensemble package lifecycle returned a failed child: \#{inspect(outputs)}"
        end

      other ->
        raise "Ensemble package lifecycle call failed: \#{inspect(other)}"
    end

    retriever = Imp.memory([[text: "France capital: Paris."]], k: 1)
    {:ok, [doc]} = Imp.retrieve(retriever, "capital France")

    unless doc.text == "France capital: Paris." do
      raise "memory retriever failed from package consumer: \#{inspect(doc)}"
    end

    {:ok, queue} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        ]
      end)

    react_lm =
      %{
        module: Imp.LM.Static,
        opts: [
          handler: fn _messages, _opts ->
            Agent.get_and_update(queue, fn
              [response | rest] -> {response, rest}
              [] -> {%{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}, []}
            end)
          end
        ]
      }

    lookup =
      Imp.tool(:lookup, "lookup facts", fn %{query: "capital-france"} -> "Paris" end)

    react = Imp.react("question -> answer: short_span", [lookup], lm: react_lm, max_iters: 3)

    {:ok, react_prediction} =
      Imp.call(react, %{question: "What city is the Eiffel Tower in?"})

    Agent.stop(queue)

    unless Imp.get(react_prediction, :answer) == "Paris" do
      raise "ReAct tool workflow failed from package consumer"
    end

    metric = Imp.exact_match(:answer)

    {:ok, best} =
      program
      |> Imp.best_of_n(metric, n: 2)
      |> Imp.call(%{question: "What city is the Eiffel Tower in?"})

    unless Imp.get(best, :answer) == "Paris" do
      raise "BestOfN facade workflow failed from package consumer"
    end

    [{:ok, batch_prediction}] =
      Imp.parallel(program, [%{question: "What city is the Eiffel Tower in?"}],
        max_concurrency: 1
      )

    unless Imp.get(batch_prediction, :answer) == "Paris" do
      raise "Parallel facade workflow failed from package consumer"
    end

    chooser =
      Imp.multi_chain_comparison("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> %{rationale: "agreement", answer: "Paris"} end]
        },
        m: 2
      )

    {:ok, chosen} =
      Imp.call(chooser, %{
        question: "What city is the Eiffel Tower in?",
        completions: [
          %{reasoning: "landmark", answer: "Paris"},
          %{reasoning: "capital", answer: "Paris"}
        ]
      })

    unless Imp.get(chosen, :answer) == "Paris" do
      raise "Multi-chain facade workflow failed from package consumer"
    end

    knn = Imp.knn(1, [demo], vectorizer: Imp.Embeddings.BagOfWords)
    [nearest] = Imp.nearest(knn, %{"question" => "Eiffel Tower city"})

    unless Imp.get(nearest, :answer) == "Paris" do
      raise "KNN facade workflow failed from package consumer"
    end

    provider = Imp.req_llm("openai:gpt-test", api_key: "sk-redacted-test", temperature: 0)
    dump = Imp.dump(Imp.predict("question -> answer", lm: provider))

    if inspect(dump) =~ "sk-redacted-test" do
      raise "provider credential leaked through save/load boundary"
    end
    """

    {deps_output, deps_status} =
      System.cmd("mix", ["deps.get"],
        cd: consumer_dir,
        stderr_to_stdout: true
      )

    assert deps_status == 0, deps_output

    {output, status} =
      System.cmd("mix", ["run", "-e", script],
        cd: consumer_dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute output =~ ~r/warning: Imp\..* is undefined/, output
  end

  defp consumer_tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "imp-package-consumer-#{System.unique_integer([:positive])}"
    ])
  end

  defp assert_manifest_sources_are_shipped(output_dir, files) do
    manifest =
      output_dir
      |> Path.join("priv/public_api.json")
      |> File.read!()
      |> Jason.decode!()

    entries = manifest["modules"]
    assert entries != []

    for entry <- entries do
      source = entry["source"]
      assert source in files, "manifest source missing from unpacked package: #{source}"
      assert File.regular?(Path.join(output_dir, source))
    end
  end

  defp documented_module_references(paths) do
    paths
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/Imp(?:\.[A-Z][A-Za-z0-9_]*)+/, &1))
      |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp documented_file_references(paths) do
    paths
    |> Enum.flat_map(fn path ->
      body = File.read!(path)

      markdown_targets =
        ~r/\]\(([^)]+)\)/
        |> Regex.scan(body)
        |> Enum.map(fn [_match, target] -> target end)

      bare_targets =
        ~r/(?:^|[\s`(])((?:\.\.\/)?(?:docs|livebooks)\/[A-Za-z0-9_\/.-]+\.(?:md|livemd)|[A-Z][A-Z0-9_]+\.md)/m
        |> Regex.scan(body)
        |> Enum.map(fn [_match, target] -> target end)

      Enum.flat_map(markdown_targets ++ bare_targets, &resolve_document_reference(path, &1))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp resolve_document_reference(source, target) do
    target =
      target
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> String.split("#", parts: 2)
      |> hd()

    cond do
      String.match?(target, ~r/^(?:https?:|mailto:|#)/) ->
        []

      String.ends_with?(target, [".md", ".livemd"]) ->
        [
          reference_base(source, target)
          |> Path.join(target)
          |> Path.expand(File.cwd!())
          |> Path.relative_to(File.cwd!())
        ]

      true ->
        []
    end
  end

  defp reference_base(_source, "docs/" <> _rest), do: File.cwd!()
  defp reference_base(_source, "livebooks/" <> _rest), do: File.cwd!()
  defp reference_base(source, _target), do: Path.dirname(source)

  defp unqualified_source_checkout_command_mentions(path) do
    lines = path |> File.read!() |> String.split("\n")

    if source_checkout_document?(lines) do
      []
    else
      unqualified_source_checkout_command_mentions(path, lines)
    end
  end

  defp unqualified_source_checkout_command_mentions(path, lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      if String.match?(line, source_checkout_command_pattern()) and
           not source_checkout_context?(lines, index) do
        ["#{path}:#{index + 1}:#{line}"]
      else
        []
      end
    end)
  end

  defp source_checkout_document?(lines) do
    lines
    |> Enum.take(12)
    |> Enum.any?(fn line ->
      normalized = String.downcase(line)

      String.contains?(normalized, "source checkout") or
        String.contains?(normalized, "source-checkout")
    end)
  end

  defp source_checkout_context?(lines, index) do
    lines
    |> Enum.slice(max(index - 12, 0), 13)
    |> Enum.any?(fn line ->
      normalized = String.downcase(line)

      String.contains?(normalized, "source checkout") or
        String.contains?(normalized, "source-checkout")
    end)
  end

  defp source_checkout_command_pattern do
    ~r/(?:LIVE_PROVIDER=1\s+)?mix (?:production\.check|public_surface\.check|integration\.check|protocol(?:\.\w+)?\.check|live\.check|livebook(?:\.execute)?\.check|package\.check|quality\.check|evidence\.check|benchmark[.\w]*)/
  end

  defp module_from_string(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end

  defp module_source_file(module) do
    Code.ensure_loaded?(module)

    module.module_info(:compile)
    |> Keyword.fetch!(:source)
    |> List.to_string()
    |> Path.relative_to(File.cwd!())
  end
end

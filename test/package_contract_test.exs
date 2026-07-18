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
    "README.md",
    "docs/API_GUIDE.md",
    "livebooks/01_real_lm_front_door.livemd",
    "livebooks/02_programming_not_prompting.livemd"
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
    "benchmarks/",
    "lib/imp/benchmark_env.ex",
    "lib/mix/tasks/imp.benchmark",
    "lib/mix/tasks/imp.gate_evidence.ex",
    "lib/imp/benchmark_truth",
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
    "lib/imp/legacy_identity_audit.ex",
    "lib/imp/benchmarks.ex",
    "lib/mix/tasks/imp.evidence.admit.ex",
    "lib/mix/tasks/imp.public_api.ex",
    "lib/mix/tasks/imp.package.clean_room.ex",
    "lib/imp/evidence_authorities.ex",
    "lib/imp/research_portfolio.ex",
    "lib/imp/upstream_authority_registry.ex",
    "lib/imp/upstream_fidelity.ex",
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

    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)
    assert hd(Keyword.fetch!(aliases, :"package.check")) == "package.clean"
    assert is_list(Keyword.fetch!(aliases, :"package.clean"))
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

  test "README installs from the Hex release, with the immutable Git tag as the pinned alternative" do
    readme = File.read!("README.md")

    # The Hex release is the primary install; the Git tag alternative must
    # reference the same version, and no floating-branch install may appear.
    assert readme =~ ~s({:imp, "~> 0.2.0"})
    assert readme =~ ~s({:imp, github: "deepfates/imp", tag: "v0.2.1"})
    refute readme =~ ~s({:imp, github: "deepfates/imp", branch: "main"})

    # The README need not offer a source-checkout install, but if it shows
    # one it must be labeled as such rather than posing as the normal path.
    if readme =~ ~s({:imp, path:) do
      assert readme =~ "source checkout"
    end
  end

  defp assert_release_files(files) do
    for file <- @product_files do
      assert file in files
    end

    for prefix <- @excluded_prefixes do
      refute Enum.any?(files, &String.starts_with?(&1, prefix))
    end

    for file <- @excluded_files do
      refute file in files
    end

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
      Imp.optimize(
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

    knn = Imp.knn(1, [demo], field: "question")
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

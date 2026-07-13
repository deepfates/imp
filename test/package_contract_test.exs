defmodule PackageContractTest do
  use ExUnit.Case, async: false

  @moduletag :package

  @product_files [
    "lib/dsex.ex",
    "lib/dsex/clients/req_llm.ex",
    "lib/dsex/lm/static.ex",
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
    "lib/dsex/benchmark_env.ex",
    "lib/mix/tasks/dsex.benchmark",
    "lib/mix/tasks/dsex.gate_evidence.ex",
    "lib/dsex/benchmark_truth",
    "scripts/dspy_",
    "test/",
    "tmp/"
  ]

  @excluded_files [
    "docs/BENCHMARK_CATALOG.md",
    "docs/BENCHMARK_TRUTH.md",
    "docs/COVERAGE_MATRIX.md",
    "docs/PARITY_VALIDATION_PROGRAM.md",
    "docs/RELEASE_CRITERIA.md",
    "lib/dsex/benchmarks.ex"
  ]

  @documented_module_allowlist MapSet.new([
                                 "DSEx.Optimize",
                                 "DSEx.Optimizer",
                                 "DSEx.TaskSupervisor",
                                 "DSEx.UnlinkedTaskSupervisor"
                               ])

  test "Hex package ships product code and docs, not local evidence machinery" do
    files =
      Mix.Project.config()
      |> Keyword.fetch!(:package)
      |> Keyword.fetch!(:files)
      |> Enum.sort()

    assert_release_files(files)
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

  test "README starts with a resolvable Git install path and labels source-checkout installs" do
    readme = File.read!("README.md")

    assert readme =~ ~s({:dsex, github: "deepfates/dsex", branch: "main"})
    assert readme =~ "source checkout"
    assert readme =~ ~s({:dsex, path: "."})
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
  end

  defp package_tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "dsex-package-contract-#{System.unique_integer([:positive])}"
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
      DSEx.MixProject.cli()
      |> Keyword.fetch!(:preferred_envs)
      |> Keyword.keys()
      |> Enum.map(&to_string/1)

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
    defmodule DSExConsumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :dsex_consumer,
          version: "0.1.0",
          elixir: "~> 1.19",
          deps: [{:dsex, path: #{inspect(package_dir)}}]
        ]
      end
    end
    """

    File.mkdir_p!(consumer_dir)
    File.write!(Path.join(consumer_dir, "mix.exs"), mix_exs)

    script = """
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)

    program =
      "question -> answer: short_span"
      |> DSEx.signature("Answer with the shortest correct span. Do not explain.")
      |> DSEx.predict()

    {:ok, prediction} =
      DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})

    unless DSEx.get(prediction, :answer) == "Paris" do
      raise "unexpected DSEx prediction: \#{inspect(prediction)}"
    end

    demo =
      DSEx.example(question: "What city is the Eiffel Tower in?", answer: "Paris")
      |> DSEx.with_inputs([:question])

    compiled =
      DSEx.optimize(
        program,
        DSEx.Optimizer.LabeledFewShot.new(k: 1),
        [demo]
      )

    {:ok, compiled_prediction} =
      DSEx.call(compiled, %{question: "What city is the Eiffel Tower in?"})

    unless DSEx.get(compiled_prediction, :answer) == "Paris" do
      raise "optimized program did not remain executable"
    end

    metric = DSEx.exact_match(:answer)
    report = DSEx.evaluate(compiled, [demo], metric)

    unless report.score == 1.0 do
      raise "facade metric/evaluation path failed from package consumer: \#{inspect(report)}"
    end

    loaded =
      compiled
      |> DSEx.dump()
      |> DSEx.load()

    {:ok, loaded_prediction} =
      DSEx.call(loaded, %{question: "What city is the Eiffel Tower in?"})

    unless DSEx.get(loaded_prediction, :answer) == "Paris" do
      raise "saved and loaded program did not remain executable"
    end

    retriever = DSEx.memory([[text: "France capital: Paris."]], k: 1)
    {:ok, [doc]} = DSEx.retrieve(retriever, "capital France")

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
        module: DSEx.LM.Static,
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
      DSEx.tool(:lookup, "lookup facts", fn %{query: "capital-france"} -> "Paris" end)

    react = DSEx.react("question -> answer: short_span", [lookup], lm: react_lm, max_iters: 3)

    {:ok, react_prediction} =
      DSEx.call(react, %{question: "What city is the Eiffel Tower in?"})

    Agent.stop(queue)

    unless DSEx.get(react_prediction, :answer) == "Paris" do
      raise "ReAct tool workflow failed from package consumer"
    end

    metric = DSEx.exact_match(:answer)

    {:ok, best} =
      program
      |> DSEx.best_of_n(metric, n: 2)
      |> DSEx.call(%{question: "What city is the Eiffel Tower in?"})

    unless DSEx.get(best, :answer) == "Paris" do
      raise "BestOfN facade workflow failed from package consumer"
    end

    [{:ok, batch_prediction}] =
      DSEx.parallel(program, [%{question: "What city is the Eiffel Tower in?"}],
        max_concurrency: 1
      )

    unless DSEx.get(batch_prediction, :answer) == "Paris" do
      raise "Parallel facade workflow failed from package consumer"
    end

    chooser =
      DSEx.multi_chain_comparison("question -> answer",
        lm: %{
          module: DSEx.LM.Static,
          opts: [handler: fn _messages, _opts -> %{rationale: "agreement", answer: "Paris"} end]
        },
        m: 2
      )

    {:ok, chosen} =
      DSEx.call(chooser, %{
        question: "What city is the Eiffel Tower in?",
        completions: [
          %{reasoning: "landmark", answer: "Paris"},
          %{reasoning: "capital", answer: "Paris"}
        ]
      })

    unless DSEx.get(chosen, :answer) == "Paris" do
      raise "Multi-chain facade workflow failed from package consumer"
    end

    knn = DSEx.knn(1, [demo], field: "question")
    [nearest] = DSEx.nearest(knn, %{"question" => "Eiffel Tower city"})

    unless DSEx.get(nearest, :answer) == "Paris" do
      raise "KNN facade workflow failed from package consumer"
    end

    provider = DSEx.req_llm("openai:gpt-test", api_key: "sk-redacted-test", temperature: 0)
    dump = DSEx.dump(DSEx.predict("question -> answer", lm: provider))

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
  end

  defp consumer_tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "dsex-package-consumer-#{System.unique_integer([:positive])}"
    ])
  end

  defp documented_module_references(paths) do
    paths
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/DSEx(?:\.[A-Z][A-Za-z0-9_]*)+/, &1))
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

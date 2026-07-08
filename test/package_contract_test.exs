defmodule PackageContractTest do
  use ExUnit.Case, async: false

  @moduletag :package

  @product_files [
    "lib/dsex.ex",
    "lib/dsex/clients/req_llm.ex",
    "lib/dsex/lm/static.ex",
    "README.md",
    "docs/API_GUIDE.md",
    "livebooks/01_programming_not_prompting.livemd"
  ]

  @excluded_prefixes [
    "benchmarks/",
    "lib/mix/tasks/dsex.benchmark",
    "lib/dsex/benchmark_truth",
    "scripts/dspy_",
    "test/",
    "tmp/"
  ]

  @excluded_files [
    "docs/BENCHMARK_TRUTH.md",
    "docs/COVERAGE_MATRIX.md",
    "docs/PARITY_VALIDATION_PROGRAM.md",
    "docs/RELEASE_CRITERIA.md",
    "lib/dsex/benchmarks.ex",
    "lib/dsex/test_mode.ex",
    "lib/dsex/lm/fake.ex",
    "lib/dsex/predict/react_v2.ex",
    "lib/dsex/clients/http_lm.ex",
    "lib/dsex/clients/providers.ex"
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

defmodule PackageContractTest do
  use ExUnit.Case, async: false

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
    "lib/dsex/benchmarks.ex",
    "lib/dsex/test_mode.ex",
    "lib/dsex/lm/fake.ex",
    "lib/dsex/predict/react_v2.ex",
    "lib/dsex/clients/http_lm.ex",
    "lib/dsex/clients/providers.ex"
  ]

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
end

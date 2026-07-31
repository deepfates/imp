defmodule Imp.LocalOptimizeAnythingRetryPolicyExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_optimize_anything_retry_policy/run.exs"

  setup_all do
    previous = System.get_env("IMP_OA_DEFINE_ONLY")
    System.put_env("IMP_OA_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_OA_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_OA_DEFINE_ONLY")
    end)

    :ok
  end

  test "task rewards executed behavior rather than artifact shape" do
    seed = apply(LocalOptimizeAnythingRetryPolicy.Task, :seed, [])
    train = apply(LocalOptimizeAnythingRetryPolicy.Task, :train, [])

    {score, info} =
      apply(LocalOptimizeAnythingRetryPolicy.Task, :evaluate, [seed, Enum.at(train, 1)])

    assert score < 1.0
    assert info.expected == 1_200
    assert info.actual != info.expected
  end

  test "front door keeps untouched rows out of selection and reloads the native artifact" do
    source = File.read!(@source)
    assert source =~ "dataset: Task.train()"
    assert source =~ "valset: Task.selection()"
    refute source =~ "valset: Task.test()"
    assert source =~ "selected-artifact.json"
    assert source =~ "Atomic.write!(result_path, Result.to_map(result))"
    assert source =~ "Report.json_safe(result.rejected)"
    assert source =~ "IMP_OA_FRESH"
    assert source =~ "IMP_OA_SELECTED_ONLY"
    assert source =~ "cache: false"
    assert source =~ "structured_response_format: :required"
  end

  test "future untouched rows are frozen canonically without evaluating them" do
    path = "examples/local_optimize_anything_retry_policy/data/untouched-v2.jsonl"
    bytes = File.read!(path)

    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
             "522245b0d7ec8d896c4b88c0475572a6325c2f25986d8b588d633bffa00590ff"

    rows = bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(rows) == 6
    assert rows |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 6
    assert rows |> Enum.map(& &1["rule"]) |> Enum.uniq() |> length() == 6

    Enum.zip(String.split(bytes, "\n", trim: true), rows)
    |> Enum.each(fn {line, row} -> assert Jason.encode!(row) == line end)
  end

  test "portfolio fresh process enters through the ordinary example" do
    source = File.read!("examples/local_optimize_anything_retry_policy/usefulness.exs")

    assert source =~ ~S|Path.join(__DIR__, "run.exs")|
    refute source =~ ~S|["run", "--no-compile", "--no-deps-check", __ENV__.file]|
  end
end

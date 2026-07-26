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
end

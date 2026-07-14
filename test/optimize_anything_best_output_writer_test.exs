defmodule Imp.Optimize.Anything.BestOutputWriterTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything.BestOutputWriter
  alias Imp.Optimizer.GEPA.Callback

  test "writes seed outputs and only later strict improvements when tracking is enabled" do
    run_dir = temporary_directory("tracked")
    {callback, writer} = BestOutputWriter.open(run_dir, true)
    on_exit(fn -> BestOutputWriter.close(writer) end)

    notify(callback, 0, 0, %{0 => 0.5}, %{0 => %{answer: "seed"}})
    notify(callback, 1, 1, %{0 => 0.5}, %{0 => %{answer: "tie"}})
    notify(callback, 2, 2, %{0 => 0.8}, %{0 => %{answer: "better"}})
    notify(callback, 3, 3, %{0 => 0.7}, %{0 => %{answer: "worse"}})

    files = Path.wildcard(Path.join(run_dir, "generated_best_outputs_valset/task_0/*.json"))
    assert Enum.map(files, &Path.basename/1) == ["iter_0_prog_0.json", "iter_2_prog_2.json"]

    better = files |> List.last() |> File.read!() |> Jason.decode!()
    assert better["score"] == 0.8
    assert better["output"] == %{"answer" => "better"}
  end

  test "writes only seed outputs when tracking is disabled and hashes unsafe task IDs" do
    run_dir = temporary_directory("seed-only")
    {callback, writer} = BestOutputWriter.open(run_dir, false)
    on_exit(fn -> BestOutputWriter.close(writer) end)
    validation_id = "../../unsafe"

    notify(callback, 0, 0, %{validation_id => 0.1}, %{validation_id => "seed"})
    notify(callback, 1, 1, %{validation_id => 1.0}, %{validation_id => "better"})

    files = Path.wildcard(Path.join(run_dir, "generated_best_outputs_valset/task_*/*.json"))
    assert length(files) == 1
    refute hd(files) =~ "unsafe"
    refute File.exists?(Path.expand("../../unsafe", run_dir))
  end

  defp notify(callback, iteration, candidate_idx, scores, outputs) do
    Callback.notify([callback], :on_valset_evaluated, %{
      iteration: iteration,
      candidate_idx: candidate_idx,
      scores_by_val_id: scores,
      outputs_by_val_id: outputs
    })
  end

  defp temporary_directory(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-best-outputs-#{label}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

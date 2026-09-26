defmodule Imp.LocalRandomSearchBanking77ExampleTest do
  use ExUnit.Case, async: false

  @source "research/local_random_search_banking77/run.exs"
  @result "research/local_random_search_banking77/exercised-result.json"

  setup_all do
    previous = System.get_env("IMP_RANDOM_SEARCH_DEFINE_ONLY")
    System.put_env("IMP_RANDOM_SEARCH_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_RANDOM_SEARCH_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_RANDOM_SEARCH_DEFINE_ONLY")
    end)

    :ok
  end

  test "retained run proves real bootstrap, honest selection, and fresh reuse" do
    result = @result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete"
    assert result["split_sizes"] == %{"train" => 16, "selection" => 8, "frozen_test" => 40}
    assert result["accepted_augmented_demos"] == 4
    assert result["augmented_demo_rendered_calls"] == 24
    assert result["optimization_calls"] == %{"task" => 32, "teacher" => 10, "transports" => 42}
    assert result["selected_kind"] == "zero_shot"
    assert result["candidate_scores"] |> hd() |> Map.fetch!("score") == 62.5
    assert result["selected_test"]["accuracy"] == 0.475
    assert result["fresh_byte_identical"]
    assert result["claim_boundary"] =~ "not general effectiveness"
  end

  test "front door keeps frozen rows outside optimization and rejects bootstrap facades" do
    source = File.read!(@source)

    assert source =~ "Imp.optimize!(source, &1, examples(rows.train), examples(rows.selection)"
    assert source =~ "examples(rows.train)"
    assert source =~ "examples(rows.selection)"
    refute source =~ "Imp.optimize!(source, &1, examples(rows.test)"
    assert source =~ "stage.accepted_augmented_demos > 0"
    assert source =~ "stage.augmented_demo_rendered_calls > 0"
    assert source =~ "TrainingJob.rebind(job, selected)"
    assert source =~ "IMP_RANDOM_SEARCH_FRESH"
  end
end

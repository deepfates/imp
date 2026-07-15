defmodule GepaCampaignTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Imp.Benchmark.GepaCampaign, as: Task

  setup do
    reporter = Task.start_progress_reporter()
    on_exit(fn -> Task.stop_progress_reporter(reporter) end)
    %{reporter: reporter}
  end

  test "optimizer checkpoints report iteration, metric calls, candidates, and cumulative usage",
       %{
         reporter: reporter
       } do
    Task.report_progress(reporter, %{event: :seed_start, family: "AIMEBench", seed: 0})

    :telemetry.execute(
      [:req_llm, :token_usage],
      %{total_cost: 0.125, tokens: %{input_tokens: 100, output_tokens: 25}},
      %{}
    )

    :telemetry.execute(
      [:req_llm, :token_usage],
      %{total_cost: 0.25, tokens: %{input_tokens: 200, output_tokens: 50}},
      %{}
    )

    :telemetry.execute(
      [:imp, :optimizer, :progress],
      %{completed_generations: 7, metric_calls: 531, candidate_count: 9},
      %{optimizer: :gepa}
    )

    assert ExUnit.CaptureIO.capture_io(fn ->
             Task.report_progress(reporter, %{
               event: :seed_checkpoint,
               phase: :optimizer,
               family: "AIMEBench",
               seed: 0,
               completed_generations: 6
             })
           end) ==
             "[GEPA] AIMEBench seed=0 optimizer checkpoint iteration=7 metric_calls=531 " <>
               "candidates=9 usage_usd=0.375000 input_tokens=300 output_tokens=75\n"
  end

  test "a new seed resets optimizer and usage observations", %{reporter: reporter} do
    :telemetry.execute(
      [:req_llm, :token_usage],
      %{total_cost: 1.0, tokens: %{input_tokens: 10, output_tokens: 5}},
      %{}
    )

    Task.report_progress(reporter, %{event: :seed_start, family: "AIMEBench", seed: 1})

    assert Task.format_optimizer_progress(
             %{family: "AIMEBench", seed: 1, completed_generations: 3},
             Agent.get(reporter.state, & &1)
           ) ==
             "[GEPA] AIMEBench seed=1 optimizer checkpoint iteration=3 metric_calls=unknown " <>
               "candidates=4 usage_usd=0.000000 input_tokens=0 output_tokens=0"
  end

  test "baseline checkpoint output remains unchanged", %{reporter: reporter} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             Task.report_progress(reporter, %{
               event: :seed_checkpoint,
               phase: :baseline,
               family: "AIMEBench",
               seed: 0,
               baseline_splits: ["dev", "train"]
             })
           end) == "[GEPA] AIMEBench seed=0 baseline checkpoint splits=dev,train\n"
  end

  test "progress reporter cleanup is idempotent", %{reporter: reporter} do
    assert :ok = Task.stop_progress_reporter(reporter)
    assert :ok = Task.stop_progress_reporter(reporter)
  end
end

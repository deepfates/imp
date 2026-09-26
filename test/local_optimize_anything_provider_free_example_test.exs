defmodule Imp.LocalOptimizeAnythingProviderFreeExampleTest do
  use ExUnit.Case, async: false

  @source "research/local_optimize_anything_retry_policy/provider_free.exs"

  setup_all do
    previous = System.get_env("IMP_OA_PROVIDER_FREE_DEFINE_ONLY")
    System.put_env("IMP_OA_PROVIDER_FREE_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_OA_PROVIDER_FREE_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_OA_PROVIDER_FREE_DEFINE_ONLY")
    end)

    :ok
  end

  test "two artifacts drive materially different executable consumers" do
    retry = LocalOptimizeAnythingProviderFree.RetryController
    scheduler = LocalOptimizeAnythingProviderFree.JobScheduler

    retry_seed = apply(retry, :seed, [])
    retry_target = apply(retry, :target, [])
    retry_row = retry |> apply(:test, []) |> hd()

    assert apply(retry, :execute, [retry_seed, retry_row]) == "manual"
    assert apply(retry, :execute, [retry_target, retry_row]) == "drop"
    assert retry_seed == apply(retry, :seed, [])

    schedule_seed = apply(scheduler, :seed, [])
    schedule_target = apply(scheduler, :target, [])
    schedule_row = scheduler |> apply(:test, []) |> hd()

    assert apply(scheduler, :execute, [schedule_seed, schedule_row]) == %{
             order: ["bulk", "critical", "standard"],
             batches: [["bulk"], ["critical"], ["standard"]]
           }

    assert apply(scheduler, :execute, [schedule_target, schedule_row]) == %{
             order: ["critical", "standard", "bulk"],
             batches: [["critical", "standard"], ["bulk"]]
           }

    assert schedule_seed == apply(scheduler, :seed, [])
  end

  @tag :tmp_dir
  test "cold public runner resumes, applies both winners, contains failures, and reproduces fresh",
       %{
         tmp_dir: tmp_dir
       } do
    output = Path.join(tmp_dir, "oa-two-domains")

    {stdout, status} =
      System.cmd("mix", ["run", "--no-compile", @source],
        cd: File.cwd!(),
        env: [
          {"MIX_ENV", "test"},
          {"IMP_OA_PROVIDER_FREE_DEFINE_ONLY", "0"},
          {"IMP_OA_PROVIDER_FREE_OUTPUT", output}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, stdout
    assert stdout =~ "provider-free Optimize Anything applications completed"

    complete = output |> Path.join("complete.json") |> File.read!() |> Jason.decode!()
    assert complete["status"] == "complete"
    assert complete["fresh_process_byte_identical"]
    assert length(complete["domains"]) == 2

    for domain <- complete["domains"] do
      assert domain["selected_selection_score"] > domain["baseline_selection_score"]
      assert domain["test_score"] == 1.0
      refute domain["resume_duplicated_calls"]
      assert domain["invalid_proposal_rejected"]

      directory = Path.join(output, domain["id"])
      assert File.regular?(Path.join(directory, "checkpoint.json"))
      assert File.regular?(Path.join(directory, "result.json"))
      assert File.regular?(Path.join(directory, "selected.json"))
      assert File.regular?(Path.join(directory, "test.json"))
    end

    retry_failure =
      output
      |> Path.join("retry-controller/invalid-proposal.json")
      |> File.read!()
      |> Jason.decode!()

    scheduler_failure =
      output
      |> Path.join("job-scheduler/invalid-proposal.json")
      |> File.read!()
      |> Jason.decode!()

    assert retry_failure["reason"] =~ "expected exact keys"
    assert scheduler_failure["reason"] =~ "changed_unselected_components"
  end

  test "front door is provider-free and keeps test rows outside optimizer inputs" do
    source = File.read!(@source)

    refute source =~ "Imp.req_llm"
    refute source =~ "Imp.LM"
    assert source =~ "dataset: domain.train()"
    assert source =~ "valset: domain.selection()"
    refute source =~ "valset: domain.test()"
    assert source =~ "Result.best_candidate(result)"
    assert source =~ "resume_state: checkpoint"
    assert source =~ "IMP_OA_PROVIDER_FREE_FRESH"
  end
end

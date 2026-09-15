defmodule Imp.FailureCampaignTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @required_iterations 10

  test "runtime settling waits for a plain process that final leak accounting includes" do
    baseline = Imp.BenchmarkTruth.FailureCampaign.runtime_snapshot()

    child =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(child), do: Process.exit(child, :kill) end)
    Process.send_after(child, :finish, 100)
    assert Process.alive?(child)
    assert :ok = Imp.BenchmarkTruth.FailureCampaign.settle_runtime(baseline)
    refute Process.alive?(child)
  end

  test "records ten clean deterministic iterations without claiming live completion" do
    artifact =
      Imp.BenchmarkTruth.FailureCampaign.run(
        iterations: @required_iterations,
        max_concurrency: 2
      )

    assert artifact["schema_version"] == 3
    assert artifact["runner"] == "imp-failure-campaign"
    refute Map.has_key?(artifact, "generated_at")

    assert artifact["summary"] == %{
             "deterministic_lanes" => 9,
             "deterministic_passing" => 9,
             "all_requested_iterations_pass" => true,
             "flake_sample_complete" => true,
             "deterministic_complete" => true,
             "local_cases" => 9,
             "local_passing" => 9,
             "local_complete" => true,
             "live_complete" => false,
             "release_complete" => false,
             "remaining_live_lanes" => 2
           }

    assert get_in(artifact, ["configuration", "runtime_warmup", "warmed_lanes"]) ==
             artifact["scope"]

    assert artifact["runtime"]["leak_free"]

    assert artifact["runtime"]["leaks"] == %{
             "admission_active" => 0,
             "admission_queued" => 0,
             "added_linked_tasks" => 0,
             "added_unlinked_tasks" => 0,
             "added_processes" => 0,
             "added_ports" => 0,
             "added_telemetry_handlers" => 0
           }

    assert artifact["telemetry"]["handler_detached"]
    assert artifact["telemetry"]["balanced_spans"]
    assert artifact["telemetry"]["metadata_secret_free"]
    assert artifact["secret_scan"]["passing"]

    assert artifact["evidence_policy"]["payloads_included"] == false
    assert Enum.all?(artifact["cases"], &(&1["flake_rate"] == 0.0))
    assert Enum.all?(artifact["cases"], &(&1["iterations"] == @required_iterations))
    assert Enum.all?(artifact["remaining"], &(&1["required"] == true))

    assert Enum.all?(
             artifact["remaining"],
             &(&1["status"] == "requires_local_operational_evidence")
           )

    refute contains_key?(artifact, "payload")

    timeout = case_by_id(artifact, "task_timeout_is_explicit_and_terminal")
    assert Enum.all?(timeout["outcomes"], &(get_in(&1, ["evidence", "outcome"]) == "timeout"))

    retry = case_by_id(artifact, "training_retry_and_idempotency_are_bounded")

    assert Enum.all?(retry["outcomes"], fn outcome ->
             evidence = outcome["evidence"]

             evidence["attempts"] == 3 and evidence["max_attempts"] == 3 and
               evidence["deterministic_key_stable"] and evidence["idempotency_header_stable"]
           end)

    assert_optimizer_evidence(
      artifact,
      "mipro_v2_durable_resume_and_tamper",
      "mipro_v2",
      "imp_mipro_v2_run",
      2
    )

    assert_optimizer_evidence(
      artifact,
      "simba_durable_resume_and_tamper",
      "simba",
      "imp_simba_run",
      1
    )
  end

  test "distinguishes requested success from the ten-iteration flake sample" do
    artifact =
      Imp.BenchmarkTruth.FailureCampaign.run(
        iterations: 2,
        max_concurrency: 2,
        iteration_timeout_ms: 15_000
      )

    assert artifact["summary"]["all_requested_iterations_pass"]
    assert artifact["summary"]["local_complete"]
    refute artifact["summary"]["flake_sample_complete"]
    refute artifact["summary"]["deterministic_complete"]
    refute artifact["summary"]["release_complete"]
  end

  test "validates the per-iteration wall-clock bound" do
    assert_raise ArgumentError, ~r/iteration_timeout_ms must be a positive integer/, fn ->
      Imp.BenchmarkTruth.FailureCampaign.run(iteration_timeout_ms: 0)
    end
  end

  test "local operational rows prove timeout and exact tool-agent recovery without providers" do
    artifact =
      Imp.BenchmarkTruth.FailureCampaign.run(
        iterations: 2,
        max_concurrency: 2,
        live: true,
        live_iterations: 2,
        live_timeout_ms: 1_000
      )

    assert artifact["summary"]["live_complete"]
    assert get_in(artifact, ["configuration", "runtime_warmup", "external_network"]) == false
    assert get_in(artifact, ["configuration", "runtime_warmup", "billable_generation"]) == false
    assert artifact["telemetry"]["balanced_spans"]
    assert artifact["secret_scan"]["passing"]

    [provider, agent] = artifact["live_cases"]

    assert Enum.all?(provider["outcomes"], fn outcome ->
             evidence = outcome["evidence"]

             evidence["provider"] == "local_injected_transport" and
               evidence["injected_timeout"] and evidence["timeout_reason"] == "timeout" and
               evidence["attempts"] == 2 and evidence["idempotency_header_stable"] and
               evidence["elapsed_ms"] <= evidence["deadline_ms"] and
               evidence["canary_included"] == false
           end)

    expected_history = [
      %{"tool" => "lookup", "result" => "transient_local_failure"},
      %{"tool" => "lookup", "result" => "pong"},
      %{"tool" => "finish", "result" => "completed"}
    ]

    assert Enum.all?(agent["outcomes"], fn outcome ->
             evidence = outcome["evidence"]

             evidence["provider"] == "local_static_lm" and evidence["tool_attempts"] == 2 and
               evidence["tool_failures"] == 1 and evidence["tool_successes"] == 1 and
               evidence["submit_calls"] == 1 and evidence["history"] == expected_history and
               evidence["elapsed_ms"] <= evidence["deadline_ms"] and
               evidence["canary_included"] == false
           end)
  end

  test "mix task writes the deterministic artifact" do
    out = Path.join(System.tmp_dir!(), "imp-failure-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(out) end)

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.FailureCampaign.run([
        "--iterations",
        Integer.to_string(@required_iterations),
        "--max-concurrency",
        "2",
        "--no-require-clean",
        "--out",
        out
      ])
    end)

    [path] = Path.wildcard(Path.join(out, "failure-campaign-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()
    assert Imp.BenchmarkTruth.ArtifactFile.read_run_json!(path) == artifact
    assert artifact["summary"]["deterministic_complete"]
    assert artifact["summary"]["local_complete"]
    refute artifact["summary"]["live_complete"]
    refute artifact["summary"]["release_complete"]
    refute contains_key?(artifact, "payload")
  end

  test "mix task rejects removed external-provider options" do
    for option <- ["--api-key-env", "--model", "--agent-model", "--base-url"] do
      assert_raise Mix.Error, ~r/invalid options/, fn ->
        Mix.Tasks.Imp.Benchmark.FailureCampaign.run([option, "dummy"])
      end
    end
  end

  defp case_by_id(artifact, id), do: Enum.find(artifact["cases"], &(&1["id"] == id))

  defp assert_optimizer_evidence(
         artifact,
         lane,
         optimizer,
         checkpoint_type,
         checkpoint_schema_version
       ) do
    campaign_case = case_by_id(artifact, lane)

    assert Enum.all?(campaign_case["outcomes"], fn outcome ->
             evidence = outcome["evidence"]

             evidence["optimizer"] == optimizer and evidence["checkpoint_type"] == checkpoint_type and
               evidence["checkpoint_schema_version"] == checkpoint_schema_version and
               evidence["exact_resume"] and
               evidence["tamper_rejected"] and evidence["checkpoint_payload_included"] == false
           end)
  end

  defp contains_key?(%{} = map, key) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &contains_key?(&1, key))
  end

  defp contains_key?(list, key) when is_list(list), do: Enum.any?(list, &contains_key?(&1, key))
  defp contains_key?(_value, _key), do: false
end

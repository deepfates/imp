defmodule Imp.BenchmarkTruth.HoverPapillonCalibrationPilotTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Imp.BenchmarkTruth.HoverPapillonCalibration, as: Pilot

  @pupa_url "https://huggingface.co/datasets/Columbia-NLP/PUPA/resolve/9981b49b6ced0033988a224b6712895ebf119294/PUPA_New.csv"
  @pupa_sha "72d7659c717706bc987f0d296d9714f63db5e75c6645376ec75380e6638b8f91"
  @private_fixture %{
    "inputs" => %{"user_query" => "Prepare a generic professional summary."},
    "labels" => %{"target_response" => "A generic professional summary.", "pii_str" => ""}
  }

  setup_all do
    {:ok, commit: git_head(".")}
  end

  test "pins only training coordinates and digests plus the exact 96-opportunity reservation" do
    payload = Pilot.rows!()
    tracked = File.read!(Pilot.rows_path())
    assert payload["derivation"]["heldout_loaded"] == false
    assert payload["authorities"] == Pilot.authorities()
    assert Enum.map(payload["rows"], & &1["id"]) == ~w(H0 H1 P0)
    assert Enum.map(payload["rows"], & &1["source_coordinate"]["split"]) == ~w(train train train)
    p0 = Enum.find(payload["rows"], &(&1["id"] == "P0"))

    assert Map.keys(p0) |> Enum.sort() ==
             ~w(id private_payload_sha256 row_sha256 source_coordinate task)

    refute tracked =~ "user_query"
    refute tracked =~ "target_response"
    refute tracked =~ "pii_str"

    assert Enum.map(Pilot.schedule(), & &1.id) |> Enum.uniq() |> length() == 96
    assert Enum.frequencies_by(Pilot.schedule(), & &1.runtime) == %{"imp" => 48, "dspy" => 48}

    assert %{
             opportunities: 96,
             input_tokens: 2_981_888,
             output_tokens: 1_572_864,
             hard_cost_usd: 5.0
           } = Pilot.reservation()

    assert_in_delta Pilot.reservation().unbuffered_usd, 0.85786624, 1.0e-10
    assert_in_delta Pilot.reservation().buffered_usd, 0.943652864, 1.0e-10
    assert git_head("tmp/gepa-artifact") == "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
    assert git_head("tmp/dspy-3.2.1") == "29448ae12756abdd14bd8796c819247ebb83673c"
  end

  @tag :evidence_infrastructure
  @tag timeout: 120_000
  test "pinned private source drives exact independent Imp and DSPy schedules", %{commit: commit} do
    previous_key = System.get_env("OPENAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    root = temp_root("complete")
    source = Path.join(root, "pupa_new.csv")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    response = Req.get!(@pupa_url, retry: false, max_retries: 0)
    assert response.status == 200
    assert sha256(response.body) == @pupa_sha
    secure_binary!(source, response.body)

    try do
      imp_root = Path.join(root, "imp")
      dspy_root = Path.join(root, "dspy")

      {imp_output, 0} = run_imp(imp_root, commit, source)
      assert imp_output =~ ~s("transports":48)
      imp = imp_root |> Path.join("imp.json") |> File.read!() |> Jason.decode!()

      assert %{"opportunity_count" => 48, "transport_count" => 48, "actual_cost_usd" => imp_cost} =
               imp["summary"]

      assert_in_delta imp_cost, 0.000168, 1.0e-12
      assert imp["imp_candidate"] == %{"commit" => commit, "tracked_clean" => true}
      assert imp["authorities"] == Pilot.authorities()
      assert Enum.all?(imp["events"], &(&1["status"] == "ok" and &1["parse_status"] == "ok"))

      assert vectors(imp["events"]) == vectors(Pilot.runtime_schedule("imp"))

      assert length(imp["outcomes"]["hover"]) == 6
      assert Enum.all?(imp["outcomes"]["papillon"], &papillon_components_complete?/1)

      {output, 0} = run_dspy(dspy_root, commit, source)
      assert output =~ ~s("transports": 48)
      upstream = dspy_root |> Path.join("dspy.json") |> File.read!() |> Jason.decode!()
      assert upstream["imp_candidate"] == %{"commit" => commit, "tracked_clean" => true}
      assert upstream["authorities"] == Pilot.authorities()
      assert upstream["condition"] == Pilot.condition()
      assert upstream["request_contract"]["model"] == "openrouter/" <> Pilot.model()

      assert upstream["request_contract"]["extra_body"]["provider"] ==
               stringify(Pilot.provider_preferences())

      assert upstream["request_contract"]["cache"] == false
      assert upstream["request_contract"]["num_retries"] == 0
      assert upstream["request_contract"]["headers"]["X-OpenRouter-Cache"] == "false"
      assert upstream["request_contract"]["headers"]["X-OpenRouter-Metadata"] == "enabled"
      refute Map.has_key?(upstream["request_contract"], "store")
      refute Map.has_key?(upstream["request_contract"]["extra_body"], "session_id")

      assert vectors(upstream["events"]) == vectors(Pilot.runtime_schedule("dspy"))

      assert Map.keys(hd(imp["events"])) |> Enum.sort() ==
               Map.keys(hd(upstream["events"])) |> Enum.sort()

      assert_runtime_message_stability!(imp["events"])
      assert_runtime_message_stability!(upstream["events"])
      assert_renderer_boundary!(imp["events"], upstream["events"])

      assert Enum.all?(upstream["events"], &(&1["status"] == "ok" and &1["parse_status"] == "ok"))
      assert Enum.all?(upstream["outcomes"]["papillon"], &papillon_components_complete?/1)

      failed_root = Path.join(root, "dspy-format-failure")

      {failed_output, 0} =
        run_dspy(failed_root, commit, source,
          IMP_CALIBRATION_DSPY_FAIL_ON: "dspy/hover/H0/r1/summarize1"
        )

      assert failed_output =~ ~s("opportunities": 48)
      assert failed_output =~ ~s("transports": 45)
      failed = failed_root |> Path.join("dspy.json") |> File.read!() |> Jason.decode!()
      assert length(failed["events"]) == 48
      assert Enum.sum(Enum.map(failed["events"], & &1["transport_count"])) == 45
      assert vectors(failed["events"]) == vectors(Pilot.runtime_schedule("dspy"))

      r1 =
        Enum.filter(
          failed["events"],
          &(&1["task"] == "hover" and &1["row"] == "H0" and &1["repetition"] == 1)
        )

      assert Enum.map(r1, & &1["status"]) == ["ok" | List.duplicate("skipped", 3)]
      assert hd(r1)["parse_status"] == "error"
      assert get_in(hd(r1), ["error", "type"]) == "AdapterParseError"
      assert Enum.map(r1, & &1["transport_count"]) == [1, 0, 0, 0]

      r2 =
        Enum.filter(
          failed["events"],
          &(&1["task"] == "hover" and &1["row"] == "H0" and &1["repetition"] == 2)
        )

      assert Enum.map(r2, & &1["status"]) == List.duplicate("ok", 4)

      assert %{"error" => %{"reason" => "redacted ordinary DSPy program/adapter failure"}} =
               hd(failed["outcomes"]["hover"])

      assert Enum.all?(failed["outcomes"]["papillon"], &papillon_components_complete?/1)

      pap_failed_root = Path.join(root, "dspy-pap-judge-failure")

      {pap_failed_output, 0} =
        run_dspy(pap_failed_root, commit, source,
          IMP_CALIBRATION_DSPY_FAIL_ON: "dspy/papillon/P0/r1/quality_ab"
        )

      assert pap_failed_output =~ ~s("opportunities": 48)
      assert pap_failed_output =~ ~s("transports": 46)

      pap_failed =
        pap_failed_root |> Path.join("dspy.json") |> File.read!() |> Jason.decode!()

      assert length(pap_failed["events"]) == 48
      assert Enum.sum(Enum.map(pap_failed["events"], & &1["transport_count"])) == 46
      assert vectors(pap_failed["events"]) == vectors(Pilot.runtime_schedule("dspy"))

      pap_r1 =
        Enum.filter(
          pap_failed["events"],
          &(&1["task"] == "papillon" and &1["repetition"] == 1)
        )

      assert Enum.map(pap_r1, & &1["status"]) ==
               List.duplicate("ok", 4) ++ List.duplicate("skipped", 2)

      assert Enum.at(pap_r1, 3)["stage"] == "quality_ab"
      assert Enum.at(pap_r1, 3)["parse_status"] == "error"
      assert get_in(Enum.at(pap_r1, 3), ["error", "type"]) == "AdapterParseError"
      assert Enum.map(pap_r1, & &1["transport_count"]) == [1, 1, 1, 1, 0, 0]

      pap_r2 =
        Enum.filter(
          pap_failed["events"],
          &(&1["task"] == "papillon" and &1["repetition"] == 2)
        )

      assert Enum.map(pap_r2, & &1["status"]) == List.duplicate("ok", 6)

      assert %{"error" => %{"type" => "AdapterParseError"}} =
               hd(pap_failed["outcomes"]["papillon"])

      assert Enum.all?(tl(pap_failed["outcomes"]["papillon"]), &papillon_components_complete?/1)

      swallowed_root = Path.join(root, "dspy-pap-swallowed-failure")

      {swallowed_output, 0} =
        run_dspy(swallowed_root, commit, source,
          IMP_CALIBRATION_DSPY_FAIL_ON: "dspy/papillon/P0/r1/rewrite"
        )

      assert swallowed_output =~ ~s("opportunities": 48)
      assert swallowed_output =~ ~s("transports": 43)
      swallowed = swallowed_root |> Path.join("dspy.json") |> File.read!() |> Jason.decode!()

      swallowed_r1 =
        Enum.filter(
          swallowed["events"],
          &(&1["task"] == "papillon" and &1["repetition"] == 1)
        )

      assert Enum.map(swallowed_r1, & &1["status"]) ==
               ["ok" | List.duplicate("skipped", 5)]

      assert get_in(hd(swallowed_r1), ["error", "type"]) == "program_failed"
      assert Enum.all?(tl(swallowed["outcomes"]["papillon"]), &papillon_components_complete?/1)

      for runtime_root <- [imp_root, dspy_root, failed_root, pap_failed_root, swallowed_root] do
        assert_private_tree!(runtime_root)
        file = if runtime_root == imp_root, do: "imp.json", else: "dspy.json"
        main = runtime_root |> Path.join(file) |> File.read!()
        refute main =~ "target_response"
        refute main =~ "pii_str"
      end
    after
      File.rm_rf(root)
      if previous_key, do: System.put_env("OPENAI_API_KEY", previous_key)
    end
  end

  test "ordinary stage failure records only that repetition's skipped suffix and resumes next repetition",
       %{commit: commit} do
    root = temp_root("short-circuit")

    try do
      result =
        Pilot.run_provider_disabled!(root,
          expected_commit: commit,
          private_pupa_fixture: @private_fixture,
          fail_on: ["imp/papillon/P0/r1/rewrite"]
        )

      assert %{opportunity_count: 48, transport_count: 43, actual_cost_usd: cost} = result.summary
      assert_in_delta cost, 0.0001505, 1.0e-12
      r1 = Enum.filter(result.events, &(&1["task"] == "papillon" and &1["repetition"] == 1))
      assert Enum.map(r1, & &1["status"]) == ["error" | List.duplicate("skipped", 5)]
      assert hd(r1)["parse_status"] == "error"
      assert Enum.map(r1, & &1["transport_count"]) == [1, 0, 0, 0, 0, 0]
      assert Enum.all?(tl(r1), &(&1["skip_reason"] == "prior_stage_failed"))

      r2 = Enum.filter(result.events, &(&1["task"] == "papillon" and &1["repetition"] == 2))
      assert Enum.map(r2, & &1["status"]) == List.duplicate("ok", 6)

      assert vectors(result.events) == vectors(Pilot.runtime_schedule("imp"))

      reconciled =
        root
        |> Path.join("live-evidence/reconciled/imp__papillon__P0__r1__rewrite.json")
        |> File.read!()
        |> Jason.decode!()

      assert %{
               "status" => "error",
               "parse_status" => "error",
               "transport_count" => 1,
               "model_response" => response_model,
               "model_effective" => endpoint_model,
               "router_metadata" => %{
                 "endpoints" => %{
                   "total" => 22,
                   "available" => [
                     %{"model" => selected_model, "provider" => "Novita", "selected" => true}
                   ]
                 }
               }
             } = reconciled

      assert response_model == Pilot.model()
      assert endpoint_model == Pilot.endpoint_model()
      assert selected_model == Pilot.endpoint_model()

      assert reconciled["error"] == %{
               "type" => "AdapterParseError",
               "reason" => "redacted provider-disabled adapter failure"
             }

      assert %{error: _} = hd(result.outcomes.papillon)
      assert Enum.all?(tl(result.outcomes.papillon), &papillon_components_complete?/1)
    after
      File.rm_rf(root)
    end
  end

  test "prospective cost guard refuses before the adapter transport",
       %{commit: commit} do
    root = temp_root("cost-guard")
    {:ok, transports} = Agent.start_link(fn -> 0 end)

    assert_raise Imp.OperationalSafetyError, ~r/complete calibration would exceed \$5.00/, fn ->
      Pilot.run_provider_disabled!(root,
        expected_commit: commit,
        private_pupa_fixture: @private_fixture,
        initial_actual_cost_usd: 4.5,
        transport_counter: transports
      )
    end

    assert Agent.get(transports, & &1) == 0
    refute File.exists?(Path.join(root, "imp.json"))

    dspy_root = temp_root("dspy-cost-guard")

    {output, status} =
      System.cmd(
        Path.expand("tmp/dspy-parity-venv/bin/python"),
        [
          "scripts/hover_papillon_calibration_upstream.py",
          "--provider-disabled",
          "--output-root",
          dspy_root
        ],
        env: [
          {"OPENAI_API_KEY", nil},
          {"OPENROUTER_API_KEY", nil},
          {"IMP_CALIBRATION_INITIAL_COST_USD", "4.5"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "complete calibration would exceed $5.00"
    refute File.exists?(dspy_root)

    {:ok, budget} = Agent.start_link(fn -> %{actual_cost_usd: 4.99} end)
    [opportunity | _] = Pilot.runtime_schedule("imp")

    assert_raise Imp.OperationalSafetyError, ~r/next transport would exceed \$5.00/, fn ->
      Pilot.pretransport_guard!(budget, opportunity)
    end

    File.rm_rf!(root)
  end

  test "pinned DSPy TrackingLive serializes and reconciles through an offline HTTP transport" do
    root = temp_root("offline-live")

    {output, 0} =
      System.cmd(
        Path.expand("tmp/dspy-parity-venv/bin/python"),
        [
          "scripts/hover_papillon_calibration_upstream.py",
          "--verify-live-transport",
          "--output-root",
          root
        ],
        env: [{"OPENAI_API_KEY", nil}, {"OPENROUTER_API_KEY", nil}],
        stderr_to_stdout: true
      )

    assert output =~ ~s("status": "offline_live_transport_verified")
    assert output =~ ~s("transports": 1)
    assert output =~ ~s("generation_404_then_200_attempts": 2)
    assert output =~ ~s("terminal_404_attempts": 3)
    assert output =~ ~s("terminal_next_stage_transports": 0)
    assert output =~ ~s("usage_drift_provisional_retained": true)
    refute File.exists?(root)
  end

  test "generation records tolerate bounded eventual availability and retain terminal evidence",
       %{
         commit: commit
       } do
    generation = %{
      "id" => "gen-delayed",
      "model" => Pilot.endpoint_model(),
      "provider_name" => "Novita",
      "cancelled" => false,
      "session_id" => nil,
      "request_id" => "req-delayed",
      "native_tokens_prompt" => 11,
      "native_tokens_completion" => 7,
      "native_tokens_cached" => 0,
      "total_cost" => 0.0000035
    }

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    fetch = fn "gen-delayed", _api_key ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      if attempt == 1, do: {:http, 404}, else: {:ok, generation}
    end

    assert Pilot.generation_metadata!("gen-delayed", "offline-key",
             attempts: 3,
             fetch: fetch,
             sleep: fn 1_000 -> :ok end
           ) == generation

    assert Agent.get(attempts, & &1) == 2

    root = temp_root("terminal-generation")
    {:ok, transports} = Agent.start_link(fn -> 0 end)
    {:ok, terminal_attempts} = Agent.start_link(fn -> 0 end)

    terminal_fetch = fn _generation_id, _api_key ->
      Agent.update(terminal_attempts, &(&1 + 1))
      {:http, 404}
    end

    assert_raise Imp.OperationalSafetyError, ~r/generation metadata HTTP 404/, fn ->
      Pilot.run_provider_disabled!(root,
        expected_commit: commit,
        private_pupa_fixture: @private_fixture,
        transport_counter: transports,
        generation_fetch: terminal_fetch,
        generation_sleep: fn 1_000 -> :ok end,
        generation_attempts: 3
      )
    end

    assert Agent.get(transports, & &1) == 1
    assert Agent.get(terminal_attempts, & &1) == 3
    refute File.exists?(Path.join(root, "imp.json"))
    assert [provisional] = Path.wildcard(Path.join(root, "live-evidence/provisional/*.json"))
    assert [] = Path.wildcard(Path.join(root, "live-evidence/reconciled/*.json"))
    record = provisional |> File.read!() |> Jason.decode!()
    [first | _] = Pilot.runtime_schedule("imp")
    first_id = first.id
    first_task = first.task
    first_row = first.row
    first_repetition = first.repetition
    first_stage = first.stage

    assert %{
             "state" => "response_received_reconciliation_pending",
             "opportunity_id" => ^first_id,
             "runtime" => "imp",
             "task" => ^first_task,
             "row" => ^first_row,
             "repetition" => ^first_repetition,
             "stage" => ^first_stage,
             "generation_id" => generation_id,
             "model_effective" => model,
             "provider_reported" => "Novita",
             "router_metadata" => %{
               "strategy" => "direct",
               "attempt" => 1,
               "endpoints" => %{"total" => 22}
             },
             "usage_reported" => %{
               "prompt_tokens" => 11,
               "completion_tokens" => 7,
               "total_tokens" => 18,
               "prompt_tokens_details" => %{"cached_tokens" => 0}
             },
             "finish_reason" => "stop",
             "message_sha256" => message_sha,
             "message_bytes" => message_bytes,
             "message_serialization" => "canonical_json_utf8_v1",
             "transport_count" => 1
           } = record

    assert is_binary(generation_id) and generation_id != ""
    assert model == Pilot.model()
    assert String.length(message_sha) == 64
    assert is_integer(message_bytes) and message_bytes > 0

    for directory <- [root, Path.join(root, "live-evidence"), Path.dirname(provisional)] do
      assert (File.stat!(directory).mode &&& 0o777) == 0o700
    end

    assert (File.stat!(provisional).mode &&& 0o777) == 0o600
    File.rm_rf!(root)
  end

  test "event guards reject duplicates, overflow, cache, drift, cap and post-hoc cost" do
    schedule = Pilot.runtime_schedule("imp")
    events = Enum.map(schedule, &event_for/1)
    [event | rest] = events
    [opportunity | _] = schedule
    assert %{transport_count: 48} = Pilot.validate_events!(events, "imp")

    assert_raise ArgumentError, ~r/fixed imp opportunity vector/, fn ->
      Pilot.validate_events!([event, event | tl(rest)], "imp")
    end

    assert_raise ArgumentError, ~r/fixed imp opportunity vector/, fn ->
      Pilot.validate_events!(events ++ [event], "imp")
    end

    for poisoned <- [
          put_in(event, ["usage", "cached_tokens"], 1),
          Map.put(event, "model_effective", "drift"),
          Map.put(event, "provider", "proxy"),
          Map.put(event, "transport_count", 2),
          Map.put(event, "message_bytes", opportunity.max_input_bytes + 1)
        ] do
      assert_raise ArgumentError, fn -> Pilot.validate_events!([poisoned | rest], "imp") end
    end

    expensive = put_in(event, ["usage", "output_tokens"], 20_000_000)

    assert_raise ArgumentError, ~r/exceeds \$5/, fn ->
      Pilot.validate_events!([expensive | rest], "imp")
    end
  end

  test "candidate and live preflight refuse ambiguity before authority" do
    refute File.exists?("/tmp/imp-calibration-wrong-commit")

    assert_raise ArgumentError, ~r/Imp candidate commit drift/, fn ->
      Pilot.run_provider_disabled!("/tmp/imp-calibration-wrong-commit",
        expected_commit: String.duplicate("0", 40),
        private_pupa_fixture: @private_fixture
      )
    end

    assert_raise ArgumentError, ~r/ambient provider API keys/, fn ->
      Pilot.provider_disabled_preflight!(%{"OPENAI_API_KEY" => "present"})
    end

    valid = %{
      "IMP_CALIBRATION_MODE" => "live",
      "OPENROUTER_API_KEY" => "secret"
    }

    assert :ok = Pilot.live_preflight!(valid)

    assert_raise ArgumentError, ~r/OpenRouter API key/, fn ->
      Pilot.live_preflight!(Map.delete(valid, "OPENROUTER_API_KEY"))
    end
  end

  test "OpenRouter catalog and route contract are exact and fail closed" do
    catalog = Pilot.validate_catalog!(catalog_fixture())
    zdr = Pilot.validate_zdr!(zdr_fixture())
    assert catalog["model"] == "deepseek/deepseek-v4-flash"
    assert catalog["endpoint_tag"] == "novita/fp8"
    assert catalog["endpoint_name"] == "Novita | deepseek/deepseek-v4-flash-20260423"
    assert catalog["pricing"] == %{"input_per_million" => 0.14, "output_per_million" => 0.28}
    assert zdr["endpoint_tag"] == "novita/fp8"

    assert Pilot.provider_preferences() == %{
             only: ["novita/fp8"],
             order: ["novita/fp8"],
             allow_fallbacks: false,
             require_parameters: true,
             data_collection: "deny",
             zdr: true,
             max_price: %{prompt: 0.14, completion: 0.28}
           }

    poisoned = put_in(catalog_fixture(), ["data", "endpoints", Access.at(0), "tag"], "other")

    assert_raise ArgumentError, ~r/exact OpenRouter endpoint/, fn ->
      Pilot.validate_catalog!(poisoned)
    end

    assert_raise ArgumentError, ~r/absent from ZDR catalog/, fn ->
      Pilot.validate_zdr!(%{"data" => []})
    end

    generation = %{
      "id" => "gen-test",
      "model" => Pilot.endpoint_model(),
      "provider_name" => "Novita",
      "cancelled" => false,
      "session_id" => nil,
      "request_id" => "req-test",
      "native_tokens_prompt" => 11,
      "native_tokens_completion" => 7,
      "native_tokens_cached" => 0,
      "total_cost" => 0.0000035
    }

    assert Pilot.validate_generation!(generation, "gen-test") == generation

    assert_raise Imp.OperationalSafetyError, ~r/usage or cost drift/, fn ->
      Pilot.validate_generation!(Map.put(generation, "native_tokens_cached", 1), "gen-test")
    end

    assert_raise Imp.OperationalSafetyError, ~r/route identity drift/, fn ->
      Pilot.validate_generation!(Map.put(generation, "model", Pilot.model()), "gen-test")
    end
  end

  test "generation route drift is fatal after one transported stage", %{commit: commit} do
    root = temp_root("route-drift")
    {:ok, transports} = Agent.start_link(fn -> 0 end)

    fetch = fn generation_id, _api_key ->
      {:ok,
       %{
         "id" => generation_id,
         "model" => Pilot.model(),
         "provider_name" => "Novita",
         "cancelled" => false,
         "session_id" => nil,
         "request_id" => "req-route-drift",
         "native_tokens_prompt" => 11,
         "native_tokens_completion" => 7,
         "native_tokens_cached" => 0,
         "total_cost" => 0.0000035
       }}
    end

    assert_raise Imp.OperationalSafetyError, ~r/generation route identity drift/, fn ->
      Pilot.run_provider_disabled!(root,
        expected_commit: commit,
        private_pupa_fixture: @private_fixture,
        transport_counter: transports,
        generation_fetch: fetch
      )
    end

    assert Agent.get(transports, & &1) == 1
    assert [_] = Path.wildcard(Path.join(root, "live-evidence/provisional/*.json"))
    assert [] = Path.wildcard(Path.join(root, "live-evidence/reconciled/*.json"))
    refute File.exists?(Path.join(root, "imp.json"))
    File.rm_rf!(root)
  end

  defp event_for(opportunity) do
    %{
      "opportunity_id" => opportunity.id,
      "runtime" => opportunity.runtime,
      "task" => opportunity.task,
      "row" => opportunity.row,
      "repetition" => opportunity.repetition,
      "stage" => opportunity.stage,
      "model_requested" => Pilot.model(),
      "model_response" => Pilot.model(),
      "model_effective" => Pilot.endpoint_model(),
      "provider" => "openrouter",
      "upstream_provider" => "Novita",
      "endpoint_tag" => "novita/fp8",
      "request_id" => "req-test",
      "generation_id" => "gen-test",
      "message_sha256" => String.duplicate("a", 64),
      "message_bytes" => 1,
      "message_serialization" => "canonical_json_utf8_v1",
      "max_input_bytes" => opportunity.max_input_bytes,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "cached_tokens" => 0},
      "router_metadata" => %{},
      "transport_count" => 1,
      "status" => "ok"
    }
  end

  defp vectors(values), do: Enum.map(values, &vector/1)

  defp vector(%{id: id} = value),
    do: [id, value.task, value.row, value.repetition, value.stage, value.max_input_bytes]

  defp vector(value),
    do:
      Enum.map(
        ~w(opportunity_id task row repetition stage max_input_bytes),
        &Map.fetch!(value, &1)
      )

  defp papillon_components_complete?(value) do
    keys = value |> Map.keys() |> Enum.map(&to_string/1)

    Enum.all?(
      ~w(quality_ab quality_ba quality leakage_numerator leakage_denominator leakage score),
      &(&1 in keys)
    )
  end

  defp assert_runtime_message_stability!(events) do
    events
    |> Enum.group_by(&{&1["task"], &1["row"], &1["stage"]})
    |> Enum.each(fn {_stage, repetitions} ->
      assert repetitions |> Enum.map(& &1["message_sha256"]) |> Enum.uniq() |> length() == 1
    end)
  end

  defp assert_renderer_boundary!(imp_events, dspy_events) do
    imp = Map.new(imp_events, &{renderer_key(&1), &1["message_sha256"]})
    dspy = Map.new(dspy_events, &{renderer_key(&1), &1["message_sha256"]})

    assert Map.keys(imp) |> Enum.sort() == Map.keys(dspy) |> Enum.sort()

    # The ordinary Imp and DSPy Chain-of-Thought adapters render HoVer
    # differently even though the signatures, row inputs, deterministic
    # passages, prior-stage values, caps and opportunities are the same. The
    # direct query and PAPILLON program calls happen to match; structured list
    # and judge rendering remain runtime-specific treatment variables.
    matches =
      Map.new(imp, fn {{task, _row, _repetition, stage} = key, hash} ->
        {{task, stage}, hash == Map.fetch!(dspy, key)}
      end)

    assert matches == %{
             {"hover", "summarize1"} => false,
             {"hover", "query2"} => true,
             {"hover", "summarize2"} => false,
             {"hover", "query3"} => true,
             {"papillon", "rewrite"} => true,
             {"papillon", "untrusted"} => true,
             {"papillon", "response"} => true,
             {"papillon", "quality_ab"} => false,
             {"papillon", "quality_ba"} => false,
             {"papillon", "leakage"} => false
           }
  end

  defp renderer_key(event) do
    {event["task"], event["row"], event["repetition"], event["stage"]}
  end

  defp run_imp(root, commit, source) do
    System.cmd(
      "mix",
      ["run", "scripts/hover_papillon_calibration_imp.exs", "--provider-disabled", root],
      env: calibration_env(commit, source),
      stderr_to_stdout: true
    )
  end

  defp run_dspy(root, commit, source, extra_env \\ []) do
    System.cmd(
      Path.expand("tmp/dspy-parity-venv/bin/python"),
      [
        "scripts/hover_papillon_calibration_upstream.py",
        "--provider-disabled",
        "--output-root",
        root
      ],
      env:
        calibration_env(commit, source) ++
          Enum.map(extra_env, fn {key, value} -> {to_string(key), value} end),
      stderr_to_stdout: true
    )
  end

  defp calibration_env(commit, source) do
    [
      {"OPENAI_API_KEY", nil},
      {"OPENROUTER_API_KEY", nil},
      {"IMP_CALIBRATION_EXPECTED_COMMIT", commit},
      {"IMP_CALIBRATION_PUPA_SOURCE", source}
    ]
  end

  defp assert_private_tree!(root) do
    for path <- Path.wildcard(Path.join(root, "**"), match_dot: true) do
      mode = File.stat!(path).mode &&& 0o777
      if File.dir?(path), do: assert(mode == 0o700), else: assert(mode == 0o600)
    end
  end

  defp secure_binary!(path, bytes) do
    io = File.open!(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, bytes)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp temp_root(label) do
    nonce = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "imp-calibration-#{label}-#{nonce}")
  end

  defp git_head(path) do
    {head, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(head)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp catalog_fixture do
    %{
      "data" => %{
        "id" => Pilot.model(),
        "endpoints" => [
          %{
            "tag" => "novita/fp8",
            "name" => "Novita | deepseek/deepseek-v4-flash-20260423",
            "provider_name" => "Novita",
            "model_id" => Pilot.model(),
            "quantization" => "fp8",
            "status" => 0,
            "supports_implicit_caching" => false,
            "pricing" => %{"prompt" => "0.00000014", "completion" => "0.00000028"},
            "supported_parameters" => ~w(reasoning_effort max_tokens temperature)
          }
        ]
      }
    }
  end

  defp zdr_fixture do
    endpoint = catalog_fixture()["data"]["endpoints"] |> hd()
    %{"data" => [endpoint]}
  end
end

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

    assert_in_delta Pilot.reservation().unbuffered_usd, 3.70933760, 1.0e-10
    assert_in_delta Pilot.reservation().buffered_usd, 4.08027136, 1.0e-10
    assert git_head("tmp/gepa-artifact") == "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
    assert git_head("tmp/dspy-3.2.1") == "29448ae12756abdd14bd8796c819247ebb83673c"
  end

  @tag :evidence_infrastructure
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

      assert_in_delta imp_cost, 0.0007488, 1.0e-12
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

      assert vectors(upstream["events"]) == vectors(Pilot.runtime_schedule("dspy"))

      assert Map.keys(hd(imp["events"])) |> Enum.sort() ==
               Map.keys(hd(upstream["events"])) |> Enum.sort()

      assert Enum.all?(upstream["events"], &(&1["status"] == "ok" and &1["parse_status"] == "ok"))
      assert Enum.all?(upstream["outcomes"]["papillon"], &papillon_components_complete?/1)

      for runtime_root <- [imp_root, dspy_root] do
        assert_private_tree!(runtime_root)
        file = if runtime_root == dspy_root, do: "dspy.json", else: "imp.json"
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
      assert_in_delta cost, 0.0006708, 1.0e-12
      r1 = Enum.filter(result.events, &(&1["task"] == "papillon" and &1["repetition"] == 1))
      assert Enum.map(r1, & &1["status"]) == ["ok" | List.duplicate("skipped", 5)]
      assert hd(r1)["parse_status"] == "error"
      assert Enum.map(r1, & &1["transport_count"]) == [1, 0, 0, 0, 0, 0]
      assert Enum.all?(tl(r1), &(&1["skip_reason"] == "prior_stage_failed"))

      r2 = Enum.filter(result.events, &(&1["task"] == "papillon" and &1["repetition"] == 2))
      assert Enum.map(r2, & &1["status"]) == List.duplicate("ok", 6)

      assert vectors(result.events) == vectors(Pilot.runtime_schedule("imp"))

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

    assert_raise Imp.OperationalSafetyError, ~r/next transport would exceed \$5.00/, fn ->
      Pilot.run_provider_disabled!(root,
        expected_commit: commit,
        private_pupa_fixture: @private_fixture,
        initial_actual_cost_usd: 4.99,
        transport_counter: transports
      )
    end

    assert Agent.get(transports, & &1) == 0
    refute File.exists?(Path.join(root, "imp.json"))
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

    expensive = put_in(event, ["usage", "output_tokens"], 4_000_000)

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

    assert_raise ArgumentError, ~r/ambient OPENAI_API_KEY/, fn ->
      Pilot.provider_disabled_preflight!(%{"OPENAI_API_KEY" => "present"})
    end

    valid = %{
      "IMP_CALIBRATION_MODE" => "live",
      "OPENAI_API_KEY" => "secret",
      "OPENAI_PROJECT" => "dedicated-zdr-project",
      "IMP_CALIBRATION_ZDR_VERIFIED" => "true",
      "IMP_CALIBRATION_ZDR_VERIFIED_AT" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "IMP_CALIBRATION_MODEL" => Pilot.model(),
      "IMP_CALIBRATION_INPUT_USD_PER_M" => "0.40",
      "IMP_CALIBRATION_OUTPUT_USD_PER_M" => "1.60",
      "IMP_CALIBRATION_STORE" => "false",
      "IMP_CALIBRATION_RETRIES" => "0",
      "IMP_CALIBRATION_FALLBACK" => "false"
    }

    assert :ok = Pilot.live_preflight!(valid)

    assert_raise ArgumentError, ~r/ZDR/, fn ->
      Pilot.live_preflight!(Map.put(valid, "IMP_CALIBRATION_ZDR_VERIFIED", "false"))
    end
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
      "model_effective" => Pilot.model(),
      "provider" => "openai",
      "request_id" => "req-test",
      "message_sha256" => String.duplicate("a", 64),
      "message_bytes" => 1,
      "message_serialization" => "canonical_json_utf8_v1",
      "max_input_bytes" => opportunity.max_input_bytes,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "cached_tokens" => 0},
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

  defp run_imp(root, commit, source) do
    System.cmd(
      "mix",
      ["run", "scripts/hover_papillon_calibration_imp.exs", "--provider-disabled", root],
      env: calibration_env(commit, source),
      stderr_to_stdout: true
    )
  end

  defp run_dspy(root, commit, source) do
    System.cmd(
      Path.expand("tmp/dspy-parity-venv/bin/python"),
      [
        "scripts/hover_papillon_calibration_upstream.py",
        "--provider-disabled",
        "--output-root",
        root
      ],
      env: calibration_env(commit, source),
      stderr_to_stdout: true
    )
  end

  defp calibration_env(commit, source) do
    [
      {"OPENAI_API_KEY", nil},
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
end

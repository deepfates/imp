defmodule MatchedInstructionOptimizersTRECExampleTest do
  use ExUnit.Case, async: true

  Code.require_file(
    "contract.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "two_phase.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "response_evidence.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "source_identity.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  alias MatchedInstructionOptimizersTREC.Contract
  alias MatchedInstructionOptimizersTREC.TwoPhase
  alias MatchedInstructionOptimizersTREC.SourceIdentity

  @manifest "examples/matched_instruction_optimizers_trec/contract.json"

  test "freezes exact authorities, dataset IDs, models, and runtime request controls" do
    manifest = Contract.load!(@manifest)

    assert manifest["seeds"] == [2_026_072_602, 2_026_072_603, 2_026_072_604]
    assert manifest["arms"] == ~w(baseline gepa mipro_v2)
    assert length(manifest["dataset"]["splits"]["train_ids"]) == 20
    assert length(manifest["dataset"]["splits"]["validation_ids"]) == 6
    assert length(manifest["dataset"]["splits"]["held_out_ids"]) == 40

    assert manifest["models"]["task"]["digest"] ==
             "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"

    assert manifest["models"]["optimizer"]["digest"] ==
             "ac896e5b8b34a1f4efa7b14d7520725140d5512484457fab45d2a4ea14c69dba"

    assert manifest["execution"]
           |> Map.take(~w(concurrency cache retry max_retries json_fallback fallbacks)) == %{
             "concurrency" => 1,
             "cache" => false,
             "retry" => false,
             "max_retries" => 0,
             "json_fallback" => false,
             "fallbacks" => false
           }
  end

  test "strict parser accepts only the matched ChatAdapter marker envelope" do
    assert {:ok, "K11"} =
             Contract.parse_route("[[ ## route ## ]]\nK11\n\n[[ ## completed ## ]]\n")

    assert {:ok, "K47"} = Contract.parse_route(%{"route" => "K47"})
    assert {:error, :invalid_exact_chat_marker_envelope} = Contract.parse_route("K11")

    assert {:error, :invalid_exact_chat_marker_envelope} =
             Contract.parse_route("[[ ## route ## ]]\nK99\n\n[[ ## completed ## ]]\n")

    assert {:error, :invalid_exact_route_envelope} =
             Contract.parse_route(%{"route" => "K11", "reason" => "extra"})

    assert {:error, :invalid_exact_route_envelope} =
             Contract.parse_route([%{"route" => "K11"}])
  end

  test "dry plan computes the exact matched worst-case envelope without execution" do
    plan = Contract.plan!(@manifest)

    assert plan["network_calls"] == 0
    assert plan["models_started"] == 0
    assert plan["downloads"] == 0

    assert plan["per_seed_per_runtime"] == %{
             "baseline" => %{"task_calls" => 46, "optimizer_calls" => 0, "total_calls" => 46},
             "gepa" => %{"task_calls" => 148, "optimizer_calls" => 6, "total_calls" => 154},
             "mipro_v2" => %{"task_calls" => 128, "optimizer_calls" => 3, "total_calls" => 131}
           }

    assert plan["worst_case"] == %{
             "task_calls" => 1932,
             "optimizer_calls" => 54,
             "total_calls" => 1986,
             "input_tokens" => 8_355_840,
             "output_tokens" => 151_296,
             "usd" => 0.0
           }

    assert get_in(plan, ["runtime_configs", "imp", "adapter_rendering"]) ==
             "matched_dspy_chat_adapter_markers_json_fallback_disabled_captured_exactly"

    assert get_in(plan, ["runtime_configs", "upstream", "capture", "rendered_messages"])

    assert get_in(plan, ["runtime_configs", "imp", "arm_call_ceilings"]) ==
             get_in(plan, ["runtime_configs", "upstream", "arm_call_ceilings"])
  end

  test "source, model, and request drift fail closed before a plan exists" do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    path = Path.expand(@manifest)

    assert_raise ArgumentError, ~r/DSPy source commit drift/, fn ->
      Contract.validate!(
        put_in(manifest, ["source_commits", "dspy"], "wrong"),
        path
      )
    end

    assert_raise ArgumentError, ~r/task.temperature drift/, fn ->
      Contract.validate!(
        put_in(manifest, ["execution", "request", "task", "temperature"], 0.1),
        path
      )
    end

    assert_raise ArgumentError, ~r/dataset.contract SHA-256 drift/, fn ->
      Contract.validate!(
        put_in(manifest, ["dataset", "contract_sha256"], String.duplicate("0", 64)),
        path
      )
    end
  end

  test "held-out loading cannot run until every selection has been durably sealed" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    record = fn event -> Agent.update(events, &(&1 ++ [event])) end

    {sealed, held_out} =
      TwoPhase.seal_then_load_held_out!(
        [:baseline, :gepa, :mipro_v2],
        fn arm ->
          record.({:sealed, arm})
          %{arm: arm, artifact_sha256: "sealed-#{arm}"}
        end,
        fn selections ->
          assert Enum.map(selections, & &1.arm) == [:baseline, :gepa, :mipro_v2]
          record.(:selection_receipt_fsynced)
          :ok
        end,
        fn ->
          record.(:held_out_opened)
          [:untouched]
        end
      )

    assert length(sealed) == 3
    assert held_out == [:untouched]

    assert Agent.get(events, & &1) == [
             {:sealed, :baseline},
             {:sealed, :gepa},
             {:sealed, :mipro_v2},
             :selection_receipt_fsynced,
             :held_out_opened
           ]
  end

  test "launch identity records an owned clean Git HEAD and refuses drift" do
    root =
      Path.join(System.tmp_dir!(), "imp-matched-source-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git = fn args ->
      assert {_output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    end

    git.(~w(init))
    git.(["config", "user.email", "imp@example.invalid"])
    git.(["config", "user.name", "Imp Example"])
    File.write!(Path.join(root, "tracked"), "frozen\n")
    git.(~w(add tracked))
    git.(~w(commit -m frozen))

    identity = SourceIdentity.capture_clean!(root, %{"dspy" => "d", "gepa" => "g"})
    assert identity["imp"] =~ ~r/\A[0-9a-f]{40}\z/
    assert Map.take(identity, ~w(dspy gepa)) == %{"dspy" => "d", "gepa" => "g"}

    File.write!(Path.join(root, "drift"), "untracked\n")

    assert_raise RuntimeError, ~r/launch tree is not clean/, fn ->
      SourceIdentity.capture_clean!(root, %{})
    end
  end

  test "response evidence survives a later typed parse failure" do
    envelope = %{
      __imp_lm_output__: "not valid typed output",
      __imp_lm_metadata__: %{
        req_llm: %{
          provider: "ollama",
          model: "llama3.2:3b",
          finish_reason: "stop",
          content: "not valid typed output",
          usage: %{input_tokens: 12, output_tokens: 4}
        }
      }
    }

    assert %{
             output: "not valid typed output",
             route: "ollama",
             model: "llama3.2:3b",
             finish_reason: "stop",
             content: "not valid typed output",
             input_tokens: 12,
             output_tokens: 4
           } =
             MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!({:ok, envelope})
  end
end

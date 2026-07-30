defmodule Imp.DspyOptimizerPublicWorkflowGateTest do
  use ExUnit.Case, async: false

  @python "tmp/dspy-parity-venv/bin/python"
  @dspy_root "tmp/dspy-3.2.1"
  @gepa_root "tmp/gepa-v0.1.4"

  test "pinned public GEPA and MIPRO workflows complete with every option accounted for" do
    python = Path.expand(@python)
    dspy_root = Path.expand(@dspy_root)
    gepa_root = Path.expand(@gepa_root)

    Enum.each([python, dspy_root, gepa_root], fn path ->
      unless File.exists?(path) do
        flunk("pinned DSPy/GEPA sources are required; run scripts/setup_dspy_parity_env.sh")
      end
    end)

    output =
      Path.join(System.tmp_dir!(), "imp-dspy-public-workflow-#{System.unique_integer()}.json")

    on_exit(fn -> File.rm(output) end)

    {_log, 0} =
      System.cmd(
        python,
        [
          "scripts/dspy_optimizer_public_workflow_gate.py",
          "--dspy-root",
          dspy_root,
          "--gepa-root",
          gepa_root,
          "--output",
          output
        ],
        stderr_to_stdout: true
      )

    result = output |> File.read!() |> Jason.decode!()

    assert result["status"] == "pass"
    refute result["network_authority"]
    refute result["held_out_loaded"]

    assert result["version_ownership"]["dspy_3_2_1_declares_gepa"] == "0.0.27"
    refute result["version_ownership"]["gepa_0_0_27_acceptance_criterion"]
    refute result["version_ownership"]["gepa_0_1_1_acceptance_criterion"]
    assert result["version_ownership"]["gepa_0_1_2_acceptance_criterion"]
    assert result["version_ownership"]["gepa_0_1_4_acceptance_criterion"]

    assert result["gepa"]["public_compile_completed"]
    assert result["gepa"]["adapter_constructed"] == 1
    assert result["gepa"]["candidate_count"] == 2
    assert result["gepa"]["total_metric_calls"] == 80
    assert result["gepa"]["predictor_names"] == ["draft.predict", "review.predict"]
    assert result["gepa"]["save_load_identical"]
    assert result["gepa"]["cleanup"]
    assert result["gepa"]["stopper_calls"] > 0

    assert result["gepa"]["failure_slots"]["stages"] == [
             nil,
             "parse",
             "program",
             "metric",
             nil
           ]

    success = result["gepa"]["stock_adapter_success_compatibility"]
    assert success["transcript_byte_identical"]
    assert success["messages_byte_identical"]
    assert success["reflection_byte_identical"]
    assert success["public_compile_opportunity_identical"]
    assert success["all_failure_orderings_checked"] == 120

    assert Enum.all?(result["gepa"]["option_matrix"], fn row ->
             row["status"] not in ["unsupported", "dropped"]
           end)

    assert result["mipro_v2"]["public_compile_completed"]
    assert result["mipro_v2"]["prompt_calls"] == 11
    assert result["mipro_v2"]["trial_count"] == 8
    assert result["mipro_v2"]["predictor_names"] == ["draft.predict", "review.predict"]
    assert result["mipro_v2"]["save_load_identical"]
    assert result["mipro_v2"]["cleanup"]
    assert result["mipro_v2"]["malformed_task_output_refusal"] == "AdapterParseError"

    assert result["mipro_v2"]["evaluator_failure_outcome"] ==
             "contained_as_zero_score_by_mipro_eval_candidate_program"

    assert result["mipro_v2"]["evaluator_failure_calls"] > 0

    assert result["mipro_v2"]["operational_failure"] == %{
             "calls" => 1,
             "contained" => false,
             "type" => "OperationalSafetyAbort"
           }

    options = Map.new(result["mipro_v2"]["option_matrix"], &{&1["option"], &1})
    assert options["num_candidates"]["effective"]["bootstrap"] == 4
    assert options["num_candidates"]["effective"]["proposal"] == 4
    assert options["trials"]["effective"]["optimizer_input"] == 8
    assert options["trials"]["effective"]["optuna_trials"] == 8
    assert options["trials"]["effective"]["trial_log_slots_including_default"] == 9
    refute options["minibatch"]["effective"]

    assert options["operational_safety_exception"]["status"] ==
             "fatal_guard_bypass_exercised"
  end
end

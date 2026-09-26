defmodule Imp.BenchmarkTruth.IFBenchTwoStageTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Chat
  alias Imp.BenchmarkTruth.IFBenchTwoStage
  alias Imp.Metrics
  alias Imp.Module
  alias Imp.Optimizer.TrajectoryRunner
  alias Imp.Predict.ChainOfThought
  alias Imp.Prediction
  alias Imp.ProgramParameters
  alias Imp.Signature

  test "constructs the two source-faithful ChainOfThought components" do
    program = IFBenchTwoStage.new()

    assert %ChainOfThought{} = program.generate_response_module
    assert %ChainOfThought{} = program.ensure_correct_response_module

    assert Signature.to_spec(program.generate_response_module.predict.signature) ==
             "query -> reasoning, response"

    assert program.generate_response_module.predict.signature.instructions ==
             "Respond to the query"

    assert Signature.to_spec(program.ensure_correct_response_module.predict.signature) ==
             "query, response -> reasoning, final_response"

    assert program.ensure_correct_response_module.predict.signature.instructions ==
             "Ensure the response is correct and adheres to the given constraints. Your response will be used as the final response."
  end

  test "passes query and response through both stages and returns only the final response" do
    test_pid = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "final_response" do
            send(test_pid, {:ensure_prompt, prompt})
            %{reasoning: "checked", final_response: "FINAL"}
          else
            send(test_pid, {:generate_prompt, prompt})
            %{reasoning: "drafted", response: "DRAFT"}
          end
        end
      )

    assert {:ok, prediction} =
             IFBenchTwoStage.new(lm, adapter: Chat)
             |> Module.call(%{"prompt" => "Obey these constraints"})

    assert Prediction.to_map(prediction) == %{response: "FINAL"}
    assert %{trace: %{}} = prediction.metadata
    assert_received {:generate_prompt, generate_prompt}
    assert generate_prompt =~ "Obey these constraints"
    assert_received {:ensure_prompt, ensure_prompt}
    assert ensure_prompt =~ "Obey these constraints"
    assert ensure_prompt =~ "DRAFT"
  end

  test "exposes independently mutable named predictors" do
    program = IFBenchTwoStage.new()

    assert Enum.map(ProgramParameters.predictors(program), & &1.name) == [
             :generate_response_module,
             :ensure_correct_response_module
           ]

    updated =
      program
      |> ProgramParameters.put_instruction(:generate_response_module, "Draft exactly.")
      |> ProgramParameters.put_instruction(:ensure_correct_response_module, "Check exactly.")

    assert updated.generate_response_module.predict.signature.instructions == "Draft exactly."

    assert updated.ensure_correct_response_module.predict.signature.instructions ==
             "Check exactly."
  end

  test "captures both named stages in order for optimizer trajectories" do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "final_response",
            do: %{reasoning: "checked", final_response: "FINAL"},
            else: %{reasoning: "drafted", response: "DRAFT"}
        end
      )

    program = IFBenchTwoStage.new(lm, adapter: Chat)
    example = Imp.example(prompt: "Follow this", response: "FINAL") |> Imp.with_inputs(:prompt)

    [trajectory] =
      TrajectoryRunner.run(
        program,
        [example],
        Metrics.exact_match(:response)
      )

    assert trajectory.score == 1.0

    assert Enum.map(trajectory.trace, & &1.predictor) == [
             :generate_response_module,
             :ensure_correct_response_module
           ]

    assert [generate, ensure] = trajectory.trace
    assert generate.inputs == %{query: "Follow this"}
    assert generate.outputs.response == "DRAFT"
    assert ensure.inputs == %{query: "Follow this", response: "DRAFT"}
    assert ensure.outputs.final_response == "FINAL"
  end

  test "returns the standard missing query error without calling a model" do
    assert {:error, {:missing_input_fields, [:prompt]}} =
             IFBenchTwoStage.new() |> Module.call(%{})
  end
end

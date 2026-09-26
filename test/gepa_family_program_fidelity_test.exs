defmodule Imp.GEPAFamilyProgramFidelityTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Chat
  alias Imp.Optimizer.GEPA.{Candidate, Evaluation, ProgramAdapter}
  alias Imp.Predict
  alias Imp.Predict.ChainOfThought
  alias Imp.Prediction
  alias Imp.ProgramParameters
  alias Imp.Signature

  @families [
    %{
      family: "AIMEBench",
      signature: "problem -> answer",
      instruction: "Solve the problem and provide the answer in the correct format.",
      inputs: %{problem: "Find the requested integer."}
    },
    %{
      family: "LiveBenchMathBench",
      signature: "question -> answer",
      instruction: "Solve the question and provide the answer in the correct format.",
      inputs: %{question: "Find the requested integer."}
    }
  ]

  test "AIME and LiveBench Math CoT contracts reject answer-only output accepted by Predict" do
    lm = static_lm(fn _messages -> %{answer: "42"} end)

    for family <- @families do
      signature = Imp.signature(family.signature, family.instruction)
      plain = Imp.predict(signature, lm: lm, adapter: Chat)
      cot = Imp.chain_of_thought(signature, lm: lm, adapter: Chat)

      assert Signature.output_names(plain.signature) == [:answer]
      assert Signature.output_names(cot.predict.signature) == [:reasoning, :answer]
      assert cot.predict.signature.instructions == family.instruction

      assert {:ok, plain_prediction} =
               Predict.call(plain, family.inputs),
             family.family

      assert Prediction.get(plain_prediction, :answer) == "42"

      assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: [:reasoning]}} =
               ChainOfThought.call(cot, family.inputs),
             family.family
    end
  end

  test "named main instruction optimization preserves and executes each family CoT" do
    optimized_instruction = "Return exactly 42 after showing reasoning."

    lm =
      static_lm(fn messages ->
        prompt = Enum.map_join(messages, "\n", & &1.content)

        if String.contains?(prompt, optimized_instruction) do
          %{reasoning: "The optimized named instruction was applied.", answer: "42"}
        else
          %{reasoning: "The baseline instruction remains active.", answer: "0"}
        end
      end)

    for family <- @families do
      program =
        family.signature
        |> Imp.signature(family.instruction)
        |> Imp.chain_of_thought(lm: lm, adapter: Chat)

      assert [%{name: :main, predictor: predictor}] = ProgramParameters.predictors(program)
      assert predictor.signature.instructions == family.instruction
      assert Candidate.from_program(program) == %{main: family.instruction}

      optimized = Candidate.apply_to_program(program, %{main: optimized_instruction})

      assert %ChainOfThought{} = optimized
      assert Candidate.from_program(optimized) == %{main: optimized_instruction}
      assert Signature.output_names(optimized.predict.signature) == [:reasoning, :answer]

      example =
        family.inputs
        |> Map.put(:answer, "42")
        |> Imp.Example.new()
        |> Imp.Example.with_inputs(Map.keys(family.inputs))

      metric = fn _example, prediction ->
        if Prediction.get(prediction, :answer) == "42", do: 1.0, else: 0.0
      end

      adapter = ProgramAdapter.new(program, metric)

      baseline =
        Evaluation.evaluate(adapter, [example], %{main: family.instruction}, capture_traces: true)

      optimized_result =
        Evaluation.evaluate(adapter, [example], %{main: optimized_instruction},
          capture_traces: true
        )

      assert baseline.scores == [0.0], family.family
      assert optimized_result.scores == [1.0], family.family

      assert [prediction] = optimized_result.outputs

      assert Prediction.get(prediction, :reasoning) ==
               "The optimized named instruction was applied."

      assert Prediction.get(prediction, :answer) == "42"
      assert %{main: [_trajectory]} = optimized_result.trajectories
    end
  end

  defp static_lm(handler) do
    Imp.LM.Static.new(handler: fn messages, _opts -> handler.(messages) end)
  end
end

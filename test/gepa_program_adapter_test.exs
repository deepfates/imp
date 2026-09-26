defmodule Imp.Optimizer.GEPA.ProgramAdapterTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.{Adapter, Candidate, Evaluation, ProgramAdapter}

  test "runs a real Imp program and produces component reflection records" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)

    metric = fn example, prediction, _trace ->
      %{
        score:
          if(Imp.Prediction.get(prediction, :answer) == Imp.Example.get(example, :answer),
            do: 1.0,
            else: 0.0
          ),
        feedback: "Expected #{Imp.Example.get(example, :answer)}"
      }
    end

    adapter = ProgramAdapter.new(program, metric)
    candidate = Candidate.from_program(program)

    batch = [
      %{question: "Capital of France?", answer: "Paris"}
      |> Imp.Example.new()
      |> Imp.Example.with_inputs([:question])
    ]

    result = Evaluation.evaluate(adapter, batch, candidate, capture_traces: true)

    assert result.scores == [1.0]
    assert result.metadata.metric_calls == 1
    assert [%Imp.Optimizer.Trajectory{}] = result.trajectories.main

    assert %{main: [record]} =
             Adapter.make_reflective_dataset(adapter, candidate, result, [:main])

    assert record["Inputs"] == %{question: "Capital of France?"}
    assert record["Generated Outputs"] == %{answer: "Paris"}
    assert record["Feedback"] =~ "Expected Paris"
  end

  test "uses named component feedback only for reflective evaluations" do
    owner = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)
    metric = fn _example, _prediction -> %{score: 0.5, feedback: "metric feedback"} end

    callback = fn context ->
      send(owner, {:component_feedback, context})
      %{feedback_text: "Inspect #{context.predictor_output.answer}"}
    end

    adapter = ProgramAdapter.new(program, metric, component_feedback: %{main: callback})
    candidate = Candidate.from_program(program)

    batch = [
      %{question: "Capital of France?", answer: "Paris"}
      |> Imp.Example.new()
      |> Imp.Example.with_inputs([:question])
    ]

    ordinary = Evaluation.evaluate(adapter, batch, candidate)
    refute_received {:component_feedback, _context}
    assert ordinary.side_information.main == ["metric feedback"]

    reflective = Evaluation.evaluate(adapter, batch, candidate, capture_traces: true)

    refute_received {:component_feedback, _context}
    assert reflective.side_information.main == ["metric feedback"]

    reflective_dataset =
      Adapter.make_reflective_dataset(adapter, candidate, reflective, [:main])

    assert_receive {:component_feedback, context}
    assert context.component == :main
    assert context.predictor_inputs == %{question: "Capital of France?"}
    assert context.predictor_output == %{answer: "Paris"}
    assert context.score == 0.5

    assert %{main: [%{"Feedback" => feedback}]} = reflective_dataset

    assert feedback =~ "Inspect Paris"
  end

  test "pinned v0.1.4 mode emits source-shaped string reflection records and binds resume" do
    lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris", certain: true} end)

    program = Imp.predict("question -> answer, certain: boolean", lm: lm)

    metric = fn _example, _prediction ->
      %{score: 1.0, feedback: "Expected the exact city and confidence flag."}
    end

    adapter =
      ProgramAdapter.new(program, metric, reflection_record_mode: :gepa_v0_1_4)

    candidate = Candidate.from_program(program)

    batch = [
      Imp.example(question: "Capital of France?", answer: "Paris", certain: true)
      |> Imp.with_inputs(:question)
    ]

    result = Evaluation.evaluate(adapter, batch, candidate, capture_traces: true)

    assert %{main: [record]} =
             Adapter.make_reflective_dataset(adapter, candidate, result, [:main])

    assert record == %{
             "Inputs" => %{"question" => "Capital of France?"},
             "Generated Outputs" => %{"answer" => "Paris", "certain" => "true"},
             "Feedback" => "Expected the exact city and confidence flag."
           }

    state = Adapter.snapshot_state(adapter)

    assert state == %{
             "reflection_record_mode" => "gepa_v0_1_4",
             "component_order" => [:main]
           }

    assert %ProgramAdapter{} = Adapter.restore_state(adapter, state)

    assert_raise ArgumentError, ~r/reflection record mode does not match/, fn ->
      adapter
      |> Map.put(:reflection_record_mode, :beam_native)
      |> Adapter.restore_state(state)
    end

    assert_raise ArgumentError, ~r/component order differs/, fn ->
      Adapter.restore_state(adapter, Map.put(state, "component_order", [:other]))
    end

    assert %ProgramAdapter{reflection_record_mode: :beam_native} =
             program
             |> ProgramAdapter.new(metric)
             |> Adapter.restore_state(%{})
  end

  test "rejects unknown callbacks and fails closed when callback execution breaks" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "x"} end]}
    program = Imp.predict("question -> answer", lm: lm)
    metric = fn _example, _prediction -> 1.0 end

    assert_raise ArgumentError, ~r/unknown predictors: \[:missing\]/, fn ->
      ProgramAdapter.new(program, metric, component_feedback: %{missing: fn _ -> "x" end})
    end

    adapter =
      ProgramAdapter.new(program, metric,
        component_feedback: %{main: fn _context -> raise "feedback exploded" end}
      )

    batch = [Imp.example(question: "q") |> Imp.with_inputs(:question)]

    result =
      Evaluation.evaluate(adapter, batch, Candidate.from_program(program), capture_traces: true)

    assert_raise RuntimeError, ~r/component feedback failed for :main: feedback exploded/, fn ->
      Adapter.make_reflective_dataset(adapter, Candidate.from_program(program), result, [:main])
    end
  end

  test "component feedback preserves typed operational safety" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "x"} end)
    program = Imp.predict("question -> answer", lm: lm)
    metric = fn _example, _prediction -> 1.0 end
    safety = Imp.OperationalSafetyError.exception(kind: :cost, reason: :limit)

    adapter =
      ProgramAdapter.new(program, metric,
        component_feedback: %{main: fn _context -> raise safety end}
      )

    batch = [Imp.example(question: "q") |> Imp.with_inputs(:question)]

    result =
      Evaluation.evaluate(adapter, batch, Candidate.from_program(program), capture_traces: true)

    assert_raise Imp.OperationalSafetyError, fn ->
      Adapter.make_reflective_dataset(adapter, Candidate.from_program(program), result, [:main])
    end
  end

  test "keeps program and metric failures ordered and diagnostic-only" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          if inspect(messages) =~ "program failure",
            do: {:error, :program_failure},
            else: %{answer: "ok"}
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: lm)

    metric = fn example, _prediction ->
      if Imp.Example.get(example, :question) == "metric failure",
        do: raise("metric failure"),
        else: %{score: 1.0, feedback: "ordinary success"}
    end

    batch =
      Enum.map(["success", "program failure", "metric failure"], fn question ->
        Imp.example(question: question) |> Imp.with_inputs(:question)
      end)

    adapter = ProgramAdapter.new(program, metric)
    candidate = Candidate.from_program(program)
    result = Evaluation.evaluate(adapter, batch, candidate, capture_traces: true)

    assert length(result.outputs) == 3
    assert result.scores == [1.0, 0.0, 0.0]
    assert Enum.map(result.trajectories.main, &is_nil/1) == [false, true, false]

    assert ["ordinary success", program_diagnostic, metric_diagnostic] =
             result.side_information.main

    assert program_diagnostic == %{
             diagnostic_only: true,
             error: {:invalid_lm_result, {:error, :program_failure}},
             example_index: 1,
             score: 0.0
           }

    assert metric_diagnostic == %{
             diagnostic_only: true,
             error: {:metric_error, "metric failure"},
             example_index: 2,
             score: 0.0
           }

    assert %{main: [record]} =
             Adapter.make_reflective_dataset(adapter, candidate, result, [:main])

    assert record["Feedback"] =~ "ordinary success"

    pinned = %{adapter | reflection_record_mode: :gepa_v0_1_4}

    assert %{main: [pinned_record]} =
             Adapter.make_reflective_dataset(pinned, candidate, result, [:main])

    assert pinned_record["Feedback"] == "ordinary success"

    all_orders = [
      ["success", "program failure", "metric failure"],
      ["success", "metric failure", "program failure"],
      ["program failure", "success", "metric failure"],
      ["program failure", "metric failure", "success"],
      ["metric failure", "success", "program failure"],
      ["metric failure", "program failure", "success"]
    ]

    exhaustive_batch =
      all_orders
      |> List.flatten()
      |> Enum.map(fn question ->
        Imp.example(question: question) |> Imp.with_inputs(:question)
      end)

    exhaustive =
      Evaluation.evaluate(adapter, exhaustive_batch, candidate, capture_traces: true)

    assert length(exhaustive.outputs) == 18

    assert Enum.flat_map(exhaustive.trajectories.main, fn
             nil -> []
             trajectory -> [trajectory.index]
           end) ==
             Enum.reject(0..17, fn index ->
               exhaustive_batch
               |> Enum.at(index)
               |> Imp.Example.get(:question) == "program failure"
             end)

    assert Enum.count(exhaustive.side_information.main, fn
             %{diagnostic_only: true} -> true
             _feedback -> false
           end) == 12

    assert %{main: records} =
             Adapter.make_reflective_dataset(adapter, candidate, exhaustive, [:main])

    assert length(records) == 6
  end
end

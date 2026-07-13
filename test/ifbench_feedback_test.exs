defmodule DSEx.BenchmarkTruth.IFBenchFeedbackTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.{IFBenchFeedback, IFBenchTwoStage}
  alias DSEx.Optimizer.GEPA.{Candidate, ComponentFeedback, Evaluation, ProgramAdapter}
  alias DSEx.ProgramParameters

  test "callback keys exactly match the two-stage program predictors" do
    callbacks = IFBenchFeedback.callbacks(&feedback_metric/2)

    predictor_names =
      IFBenchTwoStage.new()
      |> ProgramParameters.predictors()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert callbacks |> Map.keys() |> MapSet.new() == predictor_names
    assert is_function(callbacks.generate_response_module, 1)
    assert is_function(callbacks.ensure_correct_response_module, 1)
  end

  test "each callback evaluates its selected stage output as the IFBench response" do
    owner = self()

    metric = fn example, prediction ->
      response = DSEx.Prediction.fetch!(prediction, :response)
      send(owner, {:evaluated, example, response})
      %{score: if(response == "FINAL", do: 1.0, else: 0.0), feedback: "checked:#{response}"}
    end

    callbacks = IFBenchFeedback.callbacks(metric)
    example = ifbench_example()

    generate_context =
      context(:generate_response_module, example, %{reasoning: "draft", response: "DRAFT"})

    ensure_context =
      context(:ensure_correct_response_module, example, %{
        reasoning: "corrected",
        final_response: "FINAL"
      })

    assert callbacks.generate_response_module.(generate_context) == %{
             feedback_text: "checked:DRAFT"
           }

    assert callbacks.ensure_correct_response_module.(ensure_context) == %{
             feedback_text: "checked:FINAL"
           }

    assert_received {:evaluated, ^example, "DRAFT"}
    assert_received {:evaluated, ^example, "FINAL"}
  end

  test "stage feedback evaluation does not replace the final program score" do
    metric = fn _example, prediction ->
      case DSEx.Prediction.fetch!(prediction, :response) do
        "DRAFT" -> %{score: 0.0, feedback: "draft feedback"}
        "FINAL" -> %{score: 1.0, feedback: "final feedback"}
      end
    end

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "final_response",
            do: %{reasoning: "corrected", final_response: "FINAL"},
            else: %{reasoning: "drafted", response: "DRAFT"}
        end
      ]
    }

    program = IFBenchTwoStage.new(lm, adapter: DSEx.Adapter.Chat)

    adapter =
      ProgramAdapter.new(program, metric, component_feedback: IFBenchFeedback.callbacks(metric))

    result =
      Evaluation.evaluate(adapter, [ifbench_example()], Candidate.from_program(program),
        capture_traces: true
      )

    assert result.scores == [1.0]
    assert result.side_information.generate_response_module == ["draft feedback"]
    assert result.side_information.ensure_correct_response_module == ["final feedback"]
  end

  test "passes captured trace to arity-three metrics and fails closed without feedback" do
    owner = self()

    metric = fn _example, prediction, trace ->
      send(owner, {:metric_trace, trace})
      %{score: 1.0, feedback: "trace:#{DSEx.Prediction.fetch!(prediction, :response)}"}
    end

    callback = IFBenchFeedback.callbacks(metric).generate_response_module
    context = context(:generate_response_module, ifbench_example(), %{"response" => "DRAFT"})

    assert callback.(context) == %{feedback_text: "trace:DRAFT"}
    assert_received {:metric_trace, [%{predictor: :generate_response_module}]}

    no_feedback = IFBenchFeedback.callbacks(fn _example, _prediction -> 1.0 end)

    assert_raise ArgumentError, ~r/metric-with-feedback returned invalid feedback/, fn ->
      no_feedback.generate_response_module.(context)
    end
  end

  defp feedback_metric(_example, prediction) do
    response = DSEx.Prediction.fetch!(prediction, :response)
    %{score: 1.0, feedback: "checked:#{response}"}
  end

  defp ifbench_example do
    DSEx.example(
      prompt: "Write alpha and no commas.",
      instruction_id_list: ["keywords:existence", "punctuation:no_comma"],
      kwargs: [%{"keywords" => ["alpha"]}, %{}]
    )
    |> DSEx.with_inputs(:prompt)
  end

  defp context(component, example, predictor_output) do
    %ComponentFeedback{
      component: component,
      predictor_inputs: %{query: DSEx.Example.fetch!(example, :prompt)},
      predictor_output: predictor_output,
      example: example,
      program_output: DSEx.prediction(response: "FINAL PROGRAM OUTPUT"),
      trace: [%{predictor: component}],
      score: 0.5,
      metric_feedback: "final program feedback",
      metric_metadata: %{scope: :final_program}
    }
  end
end

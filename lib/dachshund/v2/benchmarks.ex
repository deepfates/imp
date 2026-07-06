defmodule Dachshund.V2.Benchmarks do
  @moduledoc "Deterministic V2 benchmark fixtures for production gates."

  alias Dachshund.Agent
  alias Dachshund.Optimize.Anything
  alias Dachshund.Optimize.GEPA

  def run do
    [
      structured_extraction(),
      agent_tool_task(),
      prompt_optimization(),
      arbitrary_artifact_optimization()
    ]
  end

  def assert_pass! do
    results = run()

    failures =
      Enum.reject(results, fn result ->
        result.score >= result.threshold
      end)

    if failures != [] do
      raise "V2 benchmark regressions: #{inspect(failures)}"
    end

    results
  end

  def negative_controls do
    [
      structured_extraction_negative(),
      agent_tool_task_negative(),
      prompt_optimization_negative(),
      arbitrary_artifact_optimization_negative()
    ]
  end

  def assert_negative_controls! do
    false_passes =
      Enum.filter(negative_controls(), fn result ->
        result.score >= result.threshold
      end)

    if false_passes != [] do
      raise "V2 benchmark negative controls passed unexpectedly: #{inspect(false_passes)}"
    end

    negative_controls()
  end

  defp structured_extraction do
    signature =
      Dachshund.Signature.new(%{
        inputs: [:text],
        outputs: [
          %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
          %{name: :confidence, type: :number, constraints: %{min: 0.5, max: 1.0}}
        ]
      })

    {:ok, prediction} =
      Dachshund.Adapter.JSON.parse(signature, ~s({"sentiment":"positive","confidence":0.91}), [])

    score =
      if Dachshund.Prediction.to_map(prediction) == %{sentiment: "positive", confidence: 0.91},
        do: 1.0,
        else: 0.0

    result(:structured_extraction, score)
  end

  defp agent_tool_task do
    tool = Dachshund.Tool.new(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

    agent =
      Agent.new(
        :doubler,
        fn agent, %{x: x}, runtime ->
          Agent.call_tool(agent, :double, %{x: x}, runtime)
        end,
        tools: [tool]
      )

    {:ok, %{y: 8}, runtime} = Agent.run(agent, %{x: 4})

    score = if Enum.any?(runtime.traces, &(&1.type == :tool)), do: 1.0, else: 0.0
    result(:agent_tool_task, score)
  end

  defp prompt_optimization do
    artifact = Anything.new_artifact(:prompt, "Base")

    report =
      GEPA.optimize(
        artifact,
        fn artifact, examples ->
          %{
            per_example_scores:
              Enum.map(examples, fn expected ->
                if artifact.text =~ expected, do: 1.0, else: 0.0
              end),
            asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
          }
        end,
        examples: ["Paris", "concise"],
        generations: 2,
        mutation_fn: fn _artifact, asi, _generation -> Enum.join(asi, "\n") end
      )

    result(:prompt_optimization, report.best.aggregate_score)
  end

  defp arbitrary_artifact_optimization do
    artifact = Anything.new_artifact(:config, "mode=slow")

    report =
      Anything.optimize(
        artifact,
        fn artifact, _examples ->
          cond do
            artifact.text =~ "mode=fast" and artifact.text =~ "timeout=5" -> 1.0
            artifact.text =~ "mode=fast" -> 0.5
            true -> 0.0
          end
        end,
        trials: 2,
        mutation_fn: fn _artifact, trial, _seed ->
          case trial do
            1 -> "mode=fast"
            2 -> "timeout=5"
          end
        end
      )

    result(:arbitrary_artifact_optimization, report.best.score)
  end

  defp result(name, score), do: %{name: name, score: score, threshold: 1.0}

  defp structured_extraction_negative do
    signature =
      Dachshund.Signature.new(%{
        inputs: [:text],
        outputs: [
          %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
          %{name: :confidence, type: :number, constraints: %{min: 0.5, max: 1.0}}
        ]
      })

    score =
      case Dachshund.Adapter.JSON.parse(signature, ~s({"sentiment":"mixed","confidence":0.1}), []) do
        {:ok, _prediction} -> 1.0
        {:error, _reason} -> 0.0
      end

    result(:structured_extraction_negative, score)
  end

  defp agent_tool_task_negative do
    tool = Dachshund.Tool.new(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

    agent =
      Agent.new(
        :doubler_locked,
        fn agent, %{x: x}, runtime ->
          Agent.call_tool(agent, :double, %{x: x}, runtime)
        end,
        tools: [tool],
        tool_policy: []
      )

    score =
      case Agent.run(agent, %{x: 4}) do
        {:ok, %{y: 8}, _runtime} -> 1.0
        {:error, {:tool_denied, :double}, _runtime} -> 0.0
      end

    result(:agent_tool_task_negative, score)
  end

  defp prompt_optimization_negative do
    artifact = Anything.new_artifact(:prompt, "Base")

    report =
      GEPA.optimize(
        artifact,
        fn _artifact, examples ->
          %{per_example_scores: Enum.map(examples, fn _ -> 0.0 end), asi: examples}
        end,
        examples: ["Paris", "concise"],
        generations: 1,
        mutation_fn: fn _artifact, _asi, _generation -> "still wrong" end
      )

    result(:prompt_optimization_negative, report.best.aggregate_score)
  end

  defp arbitrary_artifact_optimization_negative do
    artifact = Anything.new_artifact(:config, "mode=slow")

    report =
      Anything.optimize(
        artifact,
        fn _artifact, _examples -> 0.0 end,
        trials: 1,
        mutation_fn: fn _artifact, _trial, _seed -> "mode=slow" end
      )

    result(:arbitrary_artifact_optimization_negative, report.best.score)
  end
end

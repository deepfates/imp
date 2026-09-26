defmodule Imp.Benchmarks do
  @moduledoc false

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}

  def run do
    [
      structured_extraction(),
      supervised_tool_policy_task(),
      prompt_optimization(),
      program_reward_optimization(),
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
      raise "benchmark regressions: #{inspect(failures)}"
    end

    results
  end

  def negative_controls do
    [
      structured_extraction_negative(),
      supervised_tool_policy_task_negative(),
      prompt_optimization_negative(),
      program_reward_optimization_negative(),
      arbitrary_artifact_optimization_negative()
    ]
  end

  def assert_negative_controls! do
    false_passes =
      Enum.filter(negative_controls(), fn result ->
        result.score >= result.threshold
      end)

    if false_passes != [] do
      raise "benchmark negative controls passed unexpectedly: #{inspect(false_passes)}"
    end

    negative_controls()
  end

  defp structured_extraction do
    signature =
      Imp.Signature.new(%{
        inputs: [:text],
        outputs: [
          %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
          %{name: :confidence, type: :number, constraints: %{min: 0.5, max: 1.0}}
        ]
      })

    {:ok, prediction} =
      Imp.Adapter.JSON.parse(signature, ~s({"sentiment":"positive","confidence":0.91}), [])

    score =
      if Imp.Prediction.to_map(prediction) == %{sentiment: "positive", confidence: 0.91},
        do: 1.0,
        else: 0.0

    result(:structured_extraction, score)
  end

  defp supervised_tool_policy_task do
    tool = Imp.Tool.new(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)
    :ok = Imp.ToolPolicy.authorize([:double], tool.name, %{x: 4})
    task = Imp.Tasks.async(fn -> Imp.Tool.call(tool, %{x: 4}) end)

    score = if Task.await(task) == %{y: 8}, do: 1.0, else: 0.0
    result(:supervised_tool_policy_task, score)
  end

  defp prompt_optimization do
    report =
      Anything.run(
        "Base",
        fn candidate, expected -> if(candidate =~ expected, do: 1.0, else: 0.0) end,
        dataset: ["Paris", "concise"],
        config: deterministic_config(2),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          current = Map.fetch!(candidate, component)
          if current =~ "Paris", do: current, else: current <> "\nParis\nconcise"
        end
      )

    result(:prompt_optimization, Result.best_candidate(report) |> prompt_score())
  end

  defp program_reward_optimization do
    metric = Imp.Metrics.exact_match(:answer)
    evaluator = Imp.Evaluate.new(reward_devset(), metric)
    program = Imp.predict("question -> answer", lm: reward_lm())
    baseline = Imp.Evaluate.run(evaluator, program).score

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, reward_trainset())

    optimized = Imp.Evaluate.run(evaluator, compiled).score

    score =
      if baseline == 0.0 and optimized == 1.0,
        do: 1.0,
        else: 0.0

    result(:program_reward_optimization, score)
  end

  defp arbitrary_artifact_optimization do
    report =
      Anything.run(
        "mode=slow",
        fn candidate ->
          cond do
            candidate =~ "mode=fast" and candidate =~ "timeout=5" -> 1.0
            candidate =~ "mode=fast" -> 0.5
            true -> 0.0
          end
        end,
        config: deterministic_config(2),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          current = Map.fetch!(candidate, component)

          if current =~ "mode=fast",
            do: current <> "\ntimeout=5",
            else: current <> "\nmode=fast"
        end
      )

    result(:arbitrary_artifact_optimization, Result.best_candidate(report) |> config_score())
  end

  defp result(name, score), do: %{name: name, score: score, threshold: 1.0}

  defp structured_extraction_negative do
    signature =
      Imp.Signature.new(%{
        inputs: [:text],
        outputs: [
          %{name: :sentiment, type: :string, constraints: %{enum: ["positive", "negative"]}},
          %{name: :confidence, type: :number, constraints: %{min: 0.5, max: 1.0}}
        ]
      })

    score =
      case Imp.Adapter.JSON.parse(signature, ~s({"sentiment":"mixed","confidence":0.1}), []) do
        {:ok, _prediction} -> 1.0
        {:error, _reason} -> 0.0
      end

    result(:structured_extraction_negative, score)
  end

  defp supervised_tool_policy_task_negative do
    score =
      case Imp.ToolPolicy.authorize([], :double, %{x: 4}) do
        :ok -> 1.0
        {:error, {:tool_denied, :double, :tool_policy}} -> 0.0
      end

    result(:supervised_tool_policy_task_negative, score)
  end

  defp prompt_optimization_negative do
    report =
      Anything.run(
        "Base",
        fn _candidate, _example -> 0.0 end,
        dataset: ["Paris", "concise"],
        config: deterministic_config(1),
        fallback_proposer: fn _candidate, _component, _records, _iteration -> "still wrong" end
      )

    result(:prompt_optimization_negative, Result.best_candidate(report) |> prompt_score())
  end

  defp program_reward_optimization_negative do
    metric = Imp.Metrics.exact_match(:answer)
    evaluator = Imp.Evaluate.new(reward_devset(), metric)
    program = Imp.predict("question -> answer", lm: reward_lm())

    poisoned_trainset = [
      Imp.example(question: "What is the capital of France?", answer: "London")
      |> Imp.Example.with_inputs(:question)
    ]

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, poisoned_trainset)

    result(:program_reward_optimization_negative, Imp.Evaluate.run(evaluator, compiled).score)
  end

  defp arbitrary_artifact_optimization_negative do
    report =
      Anything.run(
        "mode=slow",
        fn _candidate -> 0.0 end,
        config: deterministic_config(1),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          Map.fetch!(candidate, component) <> "\nstill slow"
        end
      )

    result(
      :arbitrary_artifact_optimization_negative,
      Result.best_candidate(report) |> config_score()
    )
  end

  defp deterministic_config(max_candidate_proposals) do
    Config.new(engine: [max_candidate_proposals: max_candidate_proposals, parallel: false])
  end

  defp prompt_score(candidate) do
    if candidate =~ "Paris" and candidate =~ "concise", do: 1.0, else: 0.0
  end

  defp config_score(candidate) do
    cond do
      candidate =~ "mode=fast" and candidate =~ "timeout=5" -> 1.0
      candidate =~ "mode=fast" -> 0.5
      true -> 0.0
    end
  end

  defp reward_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        prompt = Enum.map_join(messages, "\n", & &1.content)

        if prompt =~ "[[ ## answer ## ]]\nParis",
          do: %{answer: "Paris"},
          else: %{answer: "unknown"}
      end
    )
  end

  defp reward_trainset do
    [
      Imp.example(question: "What is the capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]
  end

  defp reward_devset do
    [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]
  end
end

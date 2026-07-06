defmodule OptimizerEffectivenessTest do
  use ExUnit.Case

  defp demo_sensitive_lm do
    %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "answer: Paris" -> %{answer: "Paris"}
            prompt =~ "Always answer Paris" -> %{answer: "Paris"}
            true -> %{answer: "unknown"}
          end
        end
      ]
    }
  end

  defp trainset do
    [
      DSEx.example(question: "What is the capital of France?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]
  end

  defp devset do
    [
      DSEx.example(question: "Capital of France?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]
  end

  test "labeled few-shot compilation improves evaluated score" do
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = DSEx.Evaluate.new(devset(), metric)

    assert DSEx.Evaluate.run(evaluator, program).score == 0.0

    compiled =
      DSEx.Optimizer.LabeledFewShot.new(k: 1)
      |> DSEx.Optimizer.LabeledFewShot.compile(program, trainset())

    assert DSEx.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "instruction optimizer can improve score using candidate instructions" do
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = DSEx.Evaluate.new(devset(), metric)
    assert DSEx.Evaluate.run(evaluator, program).score == 0.0

    optimizer =
      DSEx.Optimizer.SignatureOptimizer.new(metric,
        candidates: [
          "Answer unknown.",
          "Always answer Paris when asked about France."
        ]
      )

    compiled =
      DSEx.Optimizer.SignatureOptimizer.compile(optimizer, program, trainset(), devset())

    assert DSEx.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "random search keeps a candidate that improves dev score" do
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = DSEx.Evaluate.new(devset(), metric)

    optimizer =
      DSEx.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)

    compiled = DSEx.Optimizer.RandomSearch.compile(optimizer, program, trainset(), devset())

    assert DSEx.Evaluate.run(evaluator, compiled).score == 1.0
  end
end

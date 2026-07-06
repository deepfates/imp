defmodule OptimizerEffectivenessTest do
  use ExUnit.Case

  defp demo_sensitive_lm do
    %{
      module: Dachshund.LM.Fake,
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
      Dachshund.example(question: "What is the capital of France?", answer: "Paris")
      |> Dachshund.Example.with_inputs(:question)
    ]
  end

  defp devset do
    [
      Dachshund.example(question: "Capital of France?", answer: "Paris")
      |> Dachshund.Example.with_inputs(:question)
    ]
  end

  test "labeled few-shot compilation improves evaluated score" do
    metric = Dachshund.Metrics.exact_match(:answer)
    program = Dachshund.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Dachshund.Evaluate.new(devset(), metric)

    assert Dachshund.Evaluate.run(evaluator, program).score == 0.0

    compiled =
      Dachshund.Optimizer.LabeledFewShot.new(k: 1)
      |> Dachshund.Optimizer.LabeledFewShot.compile(program, trainset())

    assert Dachshund.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "instruction optimizer can improve score using candidate instructions" do
    metric = Dachshund.Metrics.exact_match(:answer)
    program = Dachshund.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Dachshund.Evaluate.new(devset(), metric)
    assert Dachshund.Evaluate.run(evaluator, program).score == 0.0

    optimizer =
      Dachshund.Optimizer.SignatureOptimizer.new(metric,
        candidates: [
          "Answer unknown.",
          "Always answer Paris when asked about France."
        ]
      )

    compiled =
      Dachshund.Optimizer.SignatureOptimizer.compile(optimizer, program, trainset(), devset())

    assert Dachshund.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "random search keeps a candidate that improves dev score" do
    metric = Dachshund.Metrics.exact_match(:answer)
    program = Dachshund.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Dachshund.Evaluate.new(devset(), metric)

    optimizer =
      Dachshund.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)

    compiled = Dachshund.Optimizer.RandomSearch.compile(optimizer, program, trainset(), devset())

    assert Dachshund.Evaluate.run(evaluator, compiled).score == 1.0
  end
end

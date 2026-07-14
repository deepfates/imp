defmodule OptimizerEffectivenessTest do
  use ExUnit.Case

  defp demo_sensitive_lm do
    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "[[ ## answer ## ]]\nParis" -> %{answer: "Paris"}
            prompt =~ "Always answer Paris" -> %{answer: "Paris"}
            true -> %{answer: "unknown"}
          end
        end
      ]
    }
  end

  defp trainset do
    [
      Imp.example(question: "What is the capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]
  end

  defp devset do
    [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]
  end

  test "labeled few-shot compilation improves evaluated score" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Imp.Evaluate.new(devset(), metric)

    assert Imp.Evaluate.run(evaluator, program).score == 0.0

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, trainset())

    assert Imp.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "instruction optimizer can improve score using candidate instructions" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Imp.Evaluate.new(devset(), metric)
    assert Imp.Evaluate.run(evaluator, program).score == 0.0

    optimizer =
      Imp.Optimizer.SignatureOptimizer.new(metric,
        candidates: [
          "Answer unknown.",
          "Always answer Paris when asked about France."
        ]
      )

    compiled =
      Imp.Optimizer.SignatureOptimizer.compile(optimizer, program, trainset(), devset())

    assert Imp.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "random search keeps a candidate that improves dev score" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Imp.Evaluate.new(devset(), metric)

    optimizer =
      Imp.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)

    compiled = Imp.Optimizer.RandomSearch.compile(optimizer, program, trainset(), devset())

    assert Imp.Evaluate.run(evaluator, compiled).score == 1.0
  end
end

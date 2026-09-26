defmodule OptimizerSelectionWiringTest do
  use ExUnit.Case

  defp demo_sensitive_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        prompt = Enum.map_join(messages, "\n", & &1.content)

        cond do
          prompt =~ "[[ ## answer ## ]]\nParis" -> %{answer: "Paris"}
          prompt =~ "Always answer Paris" -> %{answer: "Paris"}
          true -> %{answer: "unknown"}
        end
      end
    )
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

  test "labeled few-shot compilation injects the selected demo" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Imp.Evaluate.new(devset(), metric)

    assert Imp.Evaluate.run(evaluator, program).score == 0.0

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, trainset())

    assert Imp.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "instruction optimizer applies the selected candidate instruction" do
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

  test "random search keeps the best scripted dev-set candidate" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = Imp.Evaluate.new(devset(), metric)

    optimizer =
      Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
        num_candidate_programs: 4,
        max_bootstrapped_demos: 1
      )

    compiled =
      Imp.Optimizer.BootstrapFewShotWithRandomSearch.compile(
        optimizer,
        program,
        trainset(),
        devset()
      )

    assert Imp.Evaluate.run(evaluator, compiled).score == 1.0
  end
end

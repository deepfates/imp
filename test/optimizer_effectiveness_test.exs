defmodule OptimizerEffectivenessTest do
  use ExUnit.Case

  defp demo_sensitive_lm do
    %{
      module: DSPy.LM.Fake,
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
      DSPy.example(question: "What is the capital of France?", answer: "Paris")
      |> DSPy.Example.with_inputs(:question)
    ]
  end

  defp devset do
    [
      DSPy.example(question: "Capital of France?", answer: "Paris")
      |> DSPy.Example.with_inputs(:question)
    ]
  end

  test "labeled few-shot compilation improves evaluated score" do
    metric = DSPy.Metrics.exact_match(:answer)
    program = DSPy.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = DSPy.Evaluate.new(devset(), metric)

    assert DSPy.Evaluate.run(evaluator, program).score == 0.0

    compiled =
      DSPy.Teleprompt.LabeledFewShot.new(k: 1)
      |> DSPy.Teleprompt.LabeledFewShot.compile(program, trainset())

    assert DSPy.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "instruction optimizer can improve score using candidate instructions" do
    metric = DSPy.Metrics.exact_match(:answer)
    program = DSPy.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = DSPy.Evaluate.new(devset(), metric)
    assert DSPy.Evaluate.run(evaluator, program).score == 0.0

    optimizer =
      DSPy.Teleprompt.SignatureOptimizer.new(metric,
        candidates: [
          "Answer unknown.",
          "Always answer Paris when asked about France."
        ]
      )

    compiled =
      DSPy.Teleprompt.SignatureOptimizer.compile(optimizer, program, trainset(), devset())

    assert DSPy.Evaluate.run(evaluator, compiled).score == 1.0
  end

  test "random search keeps a candidate that improves dev score" do
    metric = DSPy.Metrics.exact_match(:answer)
    program = DSPy.predict("question -> answer", lm: demo_sensitive_lm())
    evaluator = DSPy.Evaluate.new(devset(), metric)

    optimizer = DSPy.Teleprompt.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
    compiled = DSPy.Teleprompt.RandomSearch.compile(optimizer, program, trainset(), devset())

    assert DSPy.Evaluate.run(evaluator, compiled).score == 1.0
  end
end

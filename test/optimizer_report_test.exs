defmodule OptimizerReportTest do
  use ExUnit.Case

  defp lm do
    %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "answer: Paris" or prompt =~ "Always answer Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }
  end

  defp sets do
    train = [
      DSPy.example(question: "France capital?", answer: "Paris")
      |> DSPy.Example.with_inputs(:question)
    ]

    dev = [
      DSPy.example(question: "Capital of France?", answer: "Paris")
      |> DSPy.Example.with_inputs(:question)
    ]

    {train, dev}
  end

  test "random search attaches candidate history and best score" do
    {train, dev} = sets()
    metric = DSPy.Metrics.exact_match(:answer)
    program = DSPy.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSPy.Teleprompt.RandomSearch.new(candidates: 3, demos_per_candidate: 1)
      |> DSPy.Teleprompt.RandomSearch.compile(program, train, dev)

    report = DSPy.Teleprompt.Report.fetch(compiled)

    assert %DSPy.Teleprompt.Report{optimizer: :random_search, best_score: 1.0, candidate_count: 3} =
             report

    assert Enum.all?(report.candidates, &Map.has_key?(&1, :score))
  end

  test "instruction search attaches candidate score report" do
    {_train, dev} = sets()
    metric = DSPy.Metrics.exact_match(:answer)
    program = DSPy.predict("question -> answer", lm: lm())

    compiled =
      DSPy.Teleprompt.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown.",
        "Always answer Paris."
      ])

    report = DSPy.Teleprompt.Report.fetch(compiled)
    assert report.optimizer == :instruction_search
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction == "Always answer Paris."))
  end
end
